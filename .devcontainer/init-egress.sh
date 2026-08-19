#!/bin/bash
# Startet den Egress-Proxy und schliesst das Netz für alle anderen Benutzer.
# Wird über sudo aufgerufen; es ist der einzige Befehl, den vscode so starten darf.
set -euo pipefail

PROXY_PORT=3128
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
VERIFY_ALLOWED="https://api.github.com"
VERIFY_BLOCKED="https://example.com"

echo "=================================================="
echo "Egress-Kontrolle des Containers wird eingerichtet"
echo "=================================================="

if ! iptables -L -n >/dev/null 2>&1; then
    echo "[FEHLER] iptables nicht verfügbar. Container mit --cap-add=NET_ADMIN --cap-add=NET_RAW starten." >&2
    exit 1
fi

PROXY_UID=$(id -u proxy)

# 1. Proxy starten
install -d -o proxy -g proxy /var/run/squid /var/log/squid /var/spool/squid
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
    echo "[FEHLER] Proxy hört nicht auf Port ${PROXY_PORT}." >&2
    exit 1
fi
echo "[OK] Proxy läuft (Benutzer proxy, UID ${PROXY_UID})."

# 2. Regeln setzen
iptables -F
iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Nur der Proxy darf Namen auflösen. Der Agent hat kein DNS und kann deshalb
# auch keine Daten in Anfragenamen nach aussen tragen.
for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); do
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -d "$ns" --dport 53 -j ACCEPT
    echo "  -> DNS an ${ns} nur für den Proxy"
done

# Nur der Proxy darf nach aussen. Welche Ziele er annimmt, entscheidet die
# Allowlist in /etc/squid/allowlist.txt.
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -m multiport --dports 80,443 -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

echo "=================================================="
echo "Standardrichtlinie: DROP. Ausgang nur über den Proxy."
echo "=================================================="

# 3. Wirkungsprüfung. Alle drei Punkte müssen halten.
echo "Wirkungsprüfung..."

# 3a. Ein freigegebenes Ziel muss antworten. Ohne diese Prüfung gilt eine
#     Firewall, die alles blockiert, fälschlich als fehlerfrei.
if ! curl -s --max-time 15 --proxy "$PROXY_URL" -o /dev/null "$VERIFY_ALLOWED"; then
    echo "[FEHLER] Freigegebenes Ziel ${VERIFY_ALLOWED} ist nicht erreichbar." >&2
    echo "         Allowlist unvollständig oder Proxy ohne Namensauflösung." >&2
    exit 1
fi
echo "[OK] Freigegebenes Ziel erreichbar."

# 3b. Ein nicht freigegebenes Ziel muss der Proxy abweisen.
code=$(curl -s --max-time 15 --proxy "$PROXY_URL" -o /dev/null -w '%{http_code}' "$VERIFY_BLOCKED" || true)
if [ "$code" = "200" ]; then
    echo "[FEHLER] Nicht freigegebenes Ziel ${VERIFY_BLOCKED} war erreichbar." >&2
    exit 1
fi
echo "[OK] Nicht freigegebenes Ziel abgewiesen (HTTP ${code})."

# 3c. Am Proxy vorbei darf nichts hinausgehen. Das ist die Prüfung, die eine
#     Firewall mit Adresslisten nicht bestehen kann.
if runuser -u vscode -- curl -s --max-time 8 --noproxy '*' -o /dev/null "$VERIFY_ALLOWED" 2>/dev/null; then
    echo "[FEHLER] Verbindung am Proxy vorbei war möglich." >&2
    exit 1
fi
echo "[OK] Verbindung am Proxy vorbei blockiert."

echo "[OK] Egress-Kontrolle aktiv und geprüft."
