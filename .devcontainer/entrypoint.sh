#!/bin/bash
# Richtet die Egress-Kontrolle ein, bevor irgendetwas anderes im Container
# läuft. Ohne diesen Schritt gäbe es ein Zeitfenster zwischen Containerstart
# und postStartCommand, in dem Lifecycle-Befehle und postinstall-Skripte
# ungefiltert ins Netz könnten.
#
# Der Container startet deshalb als root. Gearbeitet wird als vscode: Der
# DevContainer setzt "remoteUser": "vscode", sodass Terminals, Agent und alle
# Lifecycle-Befehle unprivilegiert laufen.
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "[FEHLER] Der Entrypoint braucht root, um die Egress-Kontrolle zu setzen." >&2
    echo "         Der Container würde sonst ohne Netzfilter starten." >&2
    echo "         Im DevContainer regelt das \"containerUser\": \"root\";" >&2
    echo "         bei docker run entsprechend -u root verwenden." >&2
    exit 1
fi

/usr/local/bin/init-egress.sh

exec "$@"
