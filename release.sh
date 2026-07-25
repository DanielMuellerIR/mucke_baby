#!/usr/bin/env bash
# release.sh — Release-DMG bauen: App bauen, signieren, notarisieren, DMG packen
# und notarisieren.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   bash build.sh    baut die App nach build/, mehr nicht
#   ./install.sh     baut, signiert, notarisiert und installiert nach /Applications
#   ./release.sh     baut, signiert, notarisiert und packt das DMG — installiert NIE
#
# Die eigentliche Arbeit macht wrappers/sign-and-release.sh; dieses Skript ist
# der einheitliche Einstiegspunkt nach dem projektübergreifenden Schema und
# reicht alle Argumente durch (z. B. --publish).
#
# Wichtig ist die doppelte Notarisierung: Erst bekommt die App ihr eigenes
# Ticket angeheftet, dann das fertige DMG. Nur so startet die App auch dann
# sauber, wenn jemand sie aus dem Image herauszieht — und bei einer Sparkle-App
# gilt das erst recht, weil das Update die neue Version selbst entpackt.
#
# Voraussetzungen:
#   - "Developer ID Application"-Zertifikat im Schlüsselbund
#   - NOTARY_PROFILE oder `git config muckeBaby.notaryProfile`
#
# Aufruf:
#   ./release.sh                     # vollständiger Release-Lauf, DMG bleibt lokal
#   ./release.sh --publish           # zusätzlich Tag + GitHub-Release (nur nach Auftrag)
#   ./release.sh --no-finder-layout  # ohne Finder-Fensterlayout (headless)
set -euo pipefail
cd "$(dirname "$0")"
exec bash wrappers/sign-and-release.sh "$@"
