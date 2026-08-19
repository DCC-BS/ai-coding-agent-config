# DevContainer: Kanton BS Secure Coding Agent Environment

Referenz-Template (Architektur 3 gemäss Leitfaden) für den sicheren Betrieb von **Claude Code** und **OpenAI Codex** in VS Code.

Das Template ist zum Ableiten gedacht. Jedes Team baut daraus seinen eigenen Container und ergänzt die Werkzeuge seines Projekts. Das DCC betreibt keine Images für andere Teams.

## Funktionsweise und Sicherheitsmerkmale
- **Plattformunabhängig:** Läuft direkt auf Linux (rootful Docker) sowie unter Windows (WSL 2 mit Docker Desktop). Zu rootless Docker siehe unten.
- **Prozess- und Dateikapselung:** Nur der freigegebene Workspace (`/workspace`) wird gemountet. Kein Zugriff auf Host-Laufwerke, Benutzerprofile oder Windows-Credentials.
- **Egress nur über einen filternden Proxy:** Standard-Richtlinie `DROP` für IPv4 und IPv6. Ausgehenden Verkehr darf allein der Benutzer `proxy` erzeugen (`iptables -m owner --uid-owner`). Der Proxy entscheidet nach Namen, nicht nach Adressen, anhand von `allowlist.txt`. Rohe IP-Adressen als Ziel weist er ab.
- **Fail-closed:** Die Regeln gelten, bevor der Proxy startet, und der Entrypoint setzt sie, bevor irgendein Lifecycle-Befehl läuft. Scheitert der Proxy, etwa an einem Tippfehler in der Allowlist, bleibt der Container ohne Netz statt ohne Filter.
- **Kein DNS für den Agenten:** Namen auflösen darf nur der Proxy. Damit lassen sich auch keine Daten in Anfragenamen nach aussen tragen.
- **Rechtebeschränkung:** Gearbeitet wird als unprivilegierter Benutzer `vscode`; Terminals, Agent und alle Lifecycle-Befehle laufen unter ihm. Der Container selbst startet als `root`, damit der Entrypoint die Egress-Kontrolle setzen kann, bevor irgendetwas anderes läuft. Passwortloses `sudo` für `vscode` ist ausschliesslich auf `/usr/local/bin/init-egress.sh` beschränkt.
- **Verwaltete Konfigurationen:**
  - Claude Code: `/etc/claude-code/managed-settings.json` (root-eigen, read-only 0444)
  - OpenAI Codex: `/etc/codex/requirements.toml` (root-eigen, read-only 0444)

## Verwendung in VS Code

### 1. Container öffnen
1. Installiere die VS Code Extension **Dev Containers** (`ms-vscode-remote.remote-containers`).
2. Öffne den Projektordner in VS Code.
3. Drücke `F1` (oder `Ctrl+Shift+P` / `Cmd+Shift+P`) und wähle **Dev Containers: Reopen in Container**.

### 2. Claude Code testen
- **CLI im Terminal:** Öffne das Terminal in VS Code und starte `claude`:
  ```bash
  claude
  ```
- **VS Code Extension:** Die Anthropic Claude Code Extension (`anthropic.claude-code`) wird automatisch im Container installiert.

### 3. OpenAI Codex testen
- **CLI im Terminal:**
  ```bash
  codex
  ```
- **Verwaltete Profile:** Codex lädt die Profile `bs-restricted-edit` und `bs-readonly` aus `/etc/codex/requirements.toml`. Prüfen lässt sich das mit:
  ```bash
  codex mcp list      # jeder Nutzer-MCP-Server muss "disabled: requirements" zeigen
  ```
  Beim Start meldet Codex `approval: untrusted` und `sandbox: workspace-write`. Versuche, das zu übersteuern (`--dangerously-bypass-approvals-and-sandbox`, `-c default_permissions=":danger-full-access"`), werden ignoriert.

### 4. Egress-Kontrolle prüfen
`init-egress.sh` prüft beim Start selbst und bricht ab, wenn eine der drei Bedingungen nicht hält. Von Hand nachvollziehen lässt sich das so:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://example.com      # 000, nicht auf der Allowlist
curl -s -o /dev/null -w '%{http_code}\n' -k https://140.82.112.3  # 000, rohe IP-Adresse
env -u https_proxy curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 https://1.1.1.1  # 000, am Proxy vorbei
getent hosts example.com    # leer, der Agent hat kein DNS
```

Die dritte und vierte Zeile unterscheiden diesen Aufbau von einer Firewall mit Adresslisten. Geprüft wird gegen eine rohe IP-Adresse und nicht gegen einen Namen: Ein Name scheitert schon an der DNS-Sperre, und die Prüfung bestünde dann auch, wenn die Firewall ein Loch hätte.

## Ein Ziel freischalten

Braucht ein Projekt einen weiteren Host, kommt sein Name in `allowlist.txt`:

```
www.bs.ch
```

Ein führender Punkt schliesst Subdomains ein (`.github.com` deckt `api.github.com` mit ab). Name und Punkt-Form dürfen nicht beide vorkommen, sonst bricht squid beim Start ab. Die Datei gehört `root` und ist im laufenden Container nicht veränderbar; Änderungen gehören ins Repository und wirken beim nächsten Bau.

Ein Name genügt, und er bleibt gültig. Das ist der Grund für den Proxy: Bei einer Firewall mit Adresslisten müsste die Adresse beim Start aufgelöst und festgeschrieben werden. Für Hosts hinter einem CDN geht das schief. `www.bs.ch` zeigt über `dualstack.t.sni.global.fastly.net` auf vier Fastly-Adressen mit einer TTL von 59 Sekunden. Beim Test funktioniert es, Stunden später nicht mehr, und der Fehler sieht aus wie ein Fehler des Agenten.

Jeder zusätzliche Eintrag ist zugleich ein Weg für Prompt Injection und für Datenabfluss. Paketquellen sind Routine. Ein Host mit beliebigen Inhalten wie `www.bs.ch` gehört ins Review.

## Eigene Toolchain ergänzen

Projektspezifische Werkzeuge kommen in den `Dockerfile` dieses Ordners, zum Beispiel:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv und eine feste Python-Version. Digest statt beweglichem Tag, damit der
# Bau reproduzierbar bleibt und niemand unbemerkt etwas anderes ausliefert.
COPY --from=ghcr.io/astral-sh/uv:0.9.7@sha256:<digest> /uv /usr/local/bin/uv
RUN uv python install 3.12

# bun aus dem Release-Archiv mit geprüfter Prüfsumme. Ein Installationsskript
# per `curl | bash` auszuführen wäre in der Bauphase besonders heikel, weil sie
# ungefiltert ins Netz darf und das Ergebnis dauerhaft im Image landet.
RUN curl -fsSLO https://github.com/oven-sh/bun/releases/download/bun-v1.2.21/bun-linux-x64.zip \
    && echo "<sha256>  bun-linux-x64.zip" | sha256sum -c - \
    && unzip -q bun-linux-x64.zip && install -m0755 bun-linux-x64/bun /usr/local/bin/bun \
    && rm -rf bun-linux-x64*

USER vscode
```

Zwei Punkte sind dabei zu beachten:

1. **Allowlist nachführen.** Was zur Laufzeit erreichbar sein soll, etwa Maven Central oder `crates.io`, gehört als Name in `allowlist.txt`.
   Was zur **Bauzeit** heruntergeladen wird, läuft an der Egress-Kontrolle vorbei und ist danach dauerhaft im Image. Diese Phase ist bewusst nicht gefiltert, das entspricht auch der Referenzumgebung von Anthropic. Sie ist dafür wie Quellcode zu behandeln: Quellen pinnen statt `curl | bash`, Images per Digest statt per Tag, und der `Dockerfile` gehört ins Review.
2. **Sicherheitsmerkmale nicht aufweichen.** Mounts, Egress-Kontrolle, unprivilegierter Benutzer und die root-eigenen Konfigurationsdateien bleiben unverändert. Wer davon abweicht, betreibt ein eigenes Einsatzprofil mit erneuter Freigabepflicht.

## Voraussetzung: rootful Docker

Der Container läuft unter dem unprivilegierten Benutzer `vscode` (UID 1000) und bindet den Projektordner des Hosts nach `/workspace`. Damit `vscode` dort schreiben kann, muss die Host-UID des Ordners unverändert im Container ankommen. Das ist der Fall bei:

- Docker Desktop unter Windows mit WSL 2 (Zielumgebung DAP),
- Docker Desktop unter macOS und Linux,
- Docker Engine im normalen, rootful Modus.

### Rootless Docker

Unter **rootless Docker** funktioniert das nicht. Dort wird die Host-UID 1000 auf die Container-UID 0 abgebildet: Der Projektordner erscheint im Container als `root:root`, und `vscode` kann nicht schreiben.

```
$ ls -ldn /workspace
drwxrwxr-x 2 0 0 4096 /workspace       # auf dem Host: 1000:1000
$ touch /workspace/probe
touch: cannot touch '/workspace/probe': Permission denied
```

Ob rootless aktiv ist, zeigt `docker info | grep -i rootless`.

Es gibt dafür keine saubere Lösung, die beide Eigenschaften erhält. `--userns=host` ändert die Abbildung nicht, `--uidmap` kennt Docker nicht (nur Podman), und `--group-add 0` macht den Workspace zwar beschreibbar, legt neue Dateien auf dem Host aber unter einer Subordinate-UID (z. B. 100999) an, an die der Host-Benutzer nicht mehr herankommt.

Bleiben zwei Wege:

1. **Rootful Docker verwenden.** Das entspricht der Zielumgebung und ist der empfohlene Weg.
2. **Für die lokale Entwicklung als Container-`root` laufen** – in `devcontainer.json`:

   ```jsonc
   "containerUser": "root",
   "remoteUser": "root"
   ```

   Unter rootless Docker ist Container-`root` auf dem Host der unprivilegierte Benutzer, neue Dateien gehören korrekt dem Host-Benutzer, und die Egress-Kontrolle wirkt unverändert. **Die verwaltete Agentenkonfiguration ist dann aber nicht mehr geschützt:** Container-`root` kann `/etc/claude-code/managed-settings.json` und `/etc/codex/requirements.toml` überschreiben. Diese Variante ist deshalb **kein freigabefähiges Einsatzprofil** nach dem Leitfaden, sondern nur für lokale Tests gedacht.

## Transferierbarkeit auf Windows (DAP)
- In VS Code auf dem Windows-Host sicherstellen:
  - `dev.containers.copyGitConfig: false` (bereits in `devcontainer.json` hinterlegt)
  - Kein aktiver SSH-Agent auf dem Host während des Container-Starts
