#!/bin/bash
# Schliesst das Netz und startet danach den Egress-Proxy.
#
# Reihenfolge ist sicherheitsrelevant: Erst gilt DROP, dann startet der Proxy.
# Scheitert der Proxy, bleibt der Container ohne Netz. Umgekehrt wäre ein
# Tippfehler in der Allowlist gleichbedeutend mit offenem Netz.
#
# Wird über sudo aufgerufen und ist der einzige Befehl, den vscode so starten darf.
# Mehrfaches Aufrufen ist zulässig und führt zum selben Zustand.
set -euo pipefail

PROXY_PORT=3128
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
AGENT_USER=vscode
VERIFY_ALLOWED="https://api.github.com"
VERIFY_BLOCKED="https://example.com"
# Feste Adresse für die Umgehungsprüfung. Bewusst eine IP und kein Name, damit
# die Prüfung an der Firewall scheitert und nicht schon an der Namensauflösung.
VERIFY_DIRECT_IP="1.1.1.1"

echo "=================================================="
echo "Egress-Kontrolle des Containers wird eingerichtet"
echo "=================================================="

if ! iptables -L -n >/dev/null 2>&1; then
    echo "[FEHLER] iptables nicht verfügbar. Container mit --cap-add=NET_ADMIN starten." >&2
    exit 1
fi

PROXY_UID=$(id -u proxy)
install -d -o proxy -g proxy /var/run/squid /var/log/squid /var/spool/squid

# ---------------------------------------------------------------- 1. IPv4 zu
iptables -F
iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Namen auflösen darf nur der Proxy. Der Agent hat kein DNS und kann deshalb
# auch keine Daten in Anfragenamen nach aussen tragen.
for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); do
    case "$ns" in
        *:*) continue ;;
    esac
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -d "$ns" --dport 53 -j ACCEPT
    echo "  -> DNS an ${ns} nur für den Proxy"
done

# Nur der Proxy darf nach aussen. Welche Ziele er annimmt, entscheidet die
# Allowlist in /etc/squid/allowlist.txt.
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -m multiport --dports 80,443 -j ACCEPT
echo "[OK] IPv4 geschlossen, Ausgang nur für den Proxy (UID ${PROXY_UID})."

# ---------------------------------------------------------------- 2. IPv6 zu
# Ohne diesen Teil wäre die gesamte Kontrolle umgehbar, sobald das Netz IPv6
# führt: Proxy, Allowlist und DNS-Sperre gelten sonst nur für IPv4.
if ip6tables -L -n >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); do
        case "$ns" in
            *:*) ;;
            *) continue ;;
        esac
        ip6tables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p udp -d "$ns" --dport 53 -j ACCEPT
        ip6tables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -d "$ns" --dport 53 -j ACCEPT
        echo "  -> DNS an ${ns} nur für den Proxy"
    done
    ip6tables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -m multiport --dports 80,443 -j ACCEPT
    echo "[OK] IPv6 geschlossen."
else
    # Kein ip6tables. Das ist nur hinnehmbar, wenn der Container auch keine
    # IPv6-Adresse besitzt, sonst stünde ein ungefilterter Weg nach aussen offen.
    if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        echo "[FEHLER] Container hat eine globale IPv6-Adresse, ip6tables ist aber nicht" >&2
        echo "         verfügbar. Der Ausgang liesse sich über IPv6 umgehen." >&2
        exit 1
    fi
    echo "[OK] Kein IPv6 im Container, ip6tables nicht erforderlich."
fi

# ---------------------------------------------------------------- 3. Proxy
squid -k parse >/dev/null
if ! pgrep -x squid >/dev/null 2>&1; then
    echo "Proxy wird gestartet..."
    squid -s
fi
for _ in $(seq 1 20); do
    ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT}" && break
    sleep 0.5
done
if ! ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT}"; then
    echo "[FEHLER] Proxy hört nicht auf Port ${PROXY_PORT}. Das Netz bleibt geschlossen." >&2
    exit 1
fi
echo "[OK] Proxy läuft."

# ---------------------------------------------------------------- 4. Prüfung
echo "Wirkungsprüfung..."

# 4a. Ein freigegebenes Ziel muss antworten. Ohne diese Prüfung gilt eine
#     Umgebung, in der nichts funktioniert, fälschlich als fehlerfrei.
if ! curl -s --max-time 20 --proxy "$PROXY_URL" -o /dev/null "$VERIFY_ALLOWED"; then
    echo "[FEHLER] Freigegebenes Ziel ${VERIFY_ALLOWED} ist nicht erreichbar." >&2
    echo "         Allowlist unvollständig oder Proxy ohne Namensauflösung." >&2
    exit 1
fi
echo "[OK] Freigegebenes Ziel erreichbar."

# 4b. Ein nicht freigegebenes Ziel muss der Proxy abweisen.
code=$(curl -s --max-time 20 --proxy "$PROXY_URL" -o /dev/null -w '%{http_code}' "$VERIFY_BLOCKED" || true)
if [ "$code" = "200" ]; then
    echo "[FEHLER] Nicht freigegebenes Ziel ${VERIFY_BLOCKED} war erreichbar." >&2
    exit 1
fi
echo "[OK] Nicht freigegebenes Ziel abgewiesen."

# 4c. Am Proxy vorbei darf nichts hinausgehen. Geprüft wird gegen eine rohe
#     IP-Adresse: Ein Name würde schon an der DNS-Sperre scheitern, und die
#     Prüfung bestünde auch dann, wenn die Firewall ein Loch hätte.
if runuser -u "$AGENT_USER" -- curl -s --max-time 8 --noproxy '*' \
        -o /dev/null "https://${VERIFY_DIRECT_IP}" 2>/dev/null; then
    echo "[FEHLER] Verbindung am Proxy vorbei war möglich (${VERIFY_DIRECT_IP})." >&2
    exit 1
fi
echo "[OK] Verbindung am Proxy vorbei blockiert."

# 4d. Der Agent darf keine Namen auflösen können.
if runuser -u "$AGENT_USER" -- timeout 6 getent hosts example.com >/dev/null 2>&1; then
    echo "[FEHLER] ${AGENT_USER} konnte einen Namen auflösen." >&2
    exit 1
fi
echo "[OK] Namensauflösung für ${AGENT_USER} blockiert."

# 4e. Rohe IP-Adressen darf auch der Proxy nicht annehmen. Sonst entschiede
#     der PTR-Eintrag des Ziels über den Zugang und nicht die Allowlist.
code=$(runuser -u "$AGENT_USER" -- curl -s --max-time 15 -o /dev/null \
        -w '%{http_code}' "https://${VERIFY_DIRECT_IP}" 2>/dev/null || true)
if [ "$code" = "200" ]; then
    echo "[FEHLER] Proxy nahm eine rohe IP-Adresse an." >&2
    exit 1
fi
echo "[OK] Rohe IP-Adressen werden abgewiesen."

echo "[OK] Egress-Kontrolle aktiv und geprüft."
