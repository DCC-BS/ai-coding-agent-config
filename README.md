# AI Coding Agent Config (DCC Basel-Stadt)

Referenzkonfiguration des Data Competence Center (DCC) am Statistischen Amt Basel-Stadt für den sicheren Betrieb von KI-Coding-Agents (Claude Code, OpenAI Codex). Sie gehört zum [Leitfaden «KI-Coding-Agents in der Softwareentwicklung sicher einsetzen»](Leitfaden.md) (Architektur 3, Anhang D).

## Was dieses Repository ist – und was nicht

Dieses Repository ist eine **Vorlage zum Ableiten**, kein zentral betriebenes Image. Das DCC stellt keine fertigen Container-Images für andere Teams bereit und pflegt keine Toolchains für fremde Projekte.

Jedes Team baut seinen eigenen DevContainer auf Basis dieser Vorlage und ergänzt die Werkzeuge, die sein Projekt braucht: `uv` und eine bestimmte Python-Version, ein JDK, `bun` oder Node, Datenbank-Clients und Ähnliches. Verbindlich bleiben dabei die Sicherheitsmerkmale unten, nicht die Werkzeugauswahl.

## Verbindliche Sicherheitsmerkmale

Diese Eigenschaften müssen in jeder abgeleiteten Variante erhalten bleiben:

1. **Nur der Workspace ist gemountet** (`/workspace`). Keine Host-Laufwerke, keine Benutzerprofile, keine Windows-Credentials, kein `/var/run/docker.sock`.
2. **Egress nur über den filternden Proxy** (`init-egress.sh`), Standardrichtlinie `DROP` für IPv4 und IPv6. Ausgehenden Verkehr darf allein der Benutzer `proxy` erzeugen; er entscheidet nach Namen aus `allowlist.txt` und weist rohe IP-Adressen ab. Der Agent hat kein DNS. Die Regeln gelten, bevor der Proxy startet und bevor ein Lifecycle-Befehl läuft, sodass ein Fehler zu einem Container ohne Netz führt und nicht zu einem ohne Filter. Beim Start prüft das Skript fünf Bedingungen und bricht bei jeder Abweichung ab.
3. **Unprivilegierter Benutzer** `vscode`. Kein allgemeines `sudo`; erlaubt ist einzig der Aufruf des Firewall-Skripts.
4. **Verwaltete Agentenkonfiguration im Image**, root-eigen und nur lesbar:
   - Claude Code: `/etc/claude-code/managed-settings.json`
   - OpenAI Codex: `/etc/codex/requirements.toml`
5. **Basis-Image über Digest referenziert**, damit der Aufbau reproduzierbar bleibt.

Punkt 3 setzt **rootful Docker** voraus (Docker Desktop oder Docker Engine im Normalmodus). Unter rootless Docker ist der gebundene Workspace für `vscode` nicht beschreibbar; die Gründe und die Behelfe stehen in [`.devcontainer/README.md`](.devcontainer/README.md#rootless-docker).

Wer eines dieser Merkmale abschwächt, betreibt ein eigenes Einsatzprofil und braucht dafür eine erneute Freigabe.

## Inhalt

| Pfad | Inhalt |
|---|---|
| `.devcontainer/devcontainer.json` | DevContainer-Definition (Mounts, Capabilities, Firewall-Start) |
| `.devcontainer/Dockerfile` | Basis-Image, Firewall-Werkzeuge, verankerte Konfiguration, `sudo`-Beschränkung |
| `.devcontainer/init-egress.sh` | Setzt die Firewall, startet den Proxy, prüft die Wirkung |
| `.devcontainer/entrypoint.sh` | Ruft die Egress-Kontrolle vor allen Lifecycle-Befehlen auf |
| `.devcontainer/squid.conf` | Proxy-Konfiguration |
| `.devcontainer/allowlist.txt` | Freigegebene Ziele, nach Namen |
| `.devcontainer/managed-settings.json` | Claude Code Referenzkonfiguration |
| `.devcontainer/requirements.toml` | Codex: Definition der kantonalen Profile und Einschränkung der wählbaren Optionen |
| `config/claude-code-settings-erweitert.example.json` | Erweitertes Beispiel mit Sandbox- und Organisationsvorgaben (Architektur 1 und 2, ohne Container) |

## Verwendung

```bash
git clone https://github.com/DCC-BS/ai-coding-agent-config.git
cp -r ai-coding-agent-config/.devcontainer <euer-projekt>/.devcontainer
```

Anschliessend im Dockerfile die eigene Toolchain ergänzen und die dafür nötigen Ziele als Namen in `allowlist.txt` eintragen. Danach in VS Code **Dev Containers: Reopen in Container**.

Haltet fest, von welchem Commit dieses Repositorys euer Container abgeleitet ist. Ohne diese Angabe ist eine Freigabe gegen einen Stand erteilt, den niemand mehr benennen kann, und eine Korrektur hier erreicht euren Container nur zufällig.

Details und Prüfschritte: [`.devcontainer/README.md`](.devcontainer/README.md).

## Vorgaben auf dem Host (DAP)

- `dev.containers.copyGitConfig` auf `false` setzen, sonst wandert die `~/.gitconfig` samt Credential-Helper in den Container.
- Beim Öffnen des Containers darf auf dem Host kein SSH-Agent laufen; er würde automatisch weitergereicht.

## Herkunft

Die Vorlage folgt der DevContainer-Referenzumgebung von Anthropic und ergänzt sie um die kantonalen Vorgaben.
