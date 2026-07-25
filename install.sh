#!/usr/bin/env bash
# install.sh — "Mucke, Baby!" notarisiert nach /Applications installieren.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   bash build.sh    baut die App nach build/, mehr nicht
#   ./install.sh     baut, signiert, notarisiert und installiert nach /Applications
#   ./release.sh     baut, signiert, notarisiert und packt das DMG — installiert nie
#
# Warum notarisiert: In /Applications gehören nur Bundles mit angeheftetem
# Notary-Ticket, die Gatekeeper akzeptiert. Ein ad-hoc signierter Testbuild
# bleibt in build/.
#
# Voraussetzungen:
#   - "Developer ID Application"-Zertifikat im Schlüsselbund
#   - NOTARY_PROFILE oder `git config muckeBaby.notaryProfile`
#
# Aufruf:  ./install.sh
# Letzte Zeile bei Erfolg: INSTALL OK: /Applications/Mucke, Baby!.app (<version>)
set -euo pipefail
cd "$(dirname "$0")"
source ./notarize-lib.sh

require_notary_profile

APP_NAME="Mucke, Baby!"
APP="build/$APP_NAME.app"
DESTINATION="/Applications/$APP_NAME.app"

# Version = einzige Quelle in Models.swift (AppInfo.version), gleiche strikte
# Extraktion wie in build.sh und sign-and-release.sh.
VERSION=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' Sources/Models.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$VERSION" ] || { echo "FEHLER: Version aus Models.swift nicht lesbar" >&2; exit 1; }

echo "=== 1/4 App bauen ==="
bash build.sh

echo "=== 2/4 Signieren (Sparkle und VLCKit von innen nach außen) ==="
sign_app_chain "$APP"

echo "=== 3/4 Notarisieren ==="
notarize_app "$APP"

echo "=== 4/4 Installieren ==="
# Erst neben das Ziel legen, dann atomar austauschen: ein Abbruch mittendrin
# darf keine halb ersetzte App in /Applications hinterlassen.
STAGED="/Applications/.$APP_NAME.app.install-$$"
rm -rf "$STAGED"
trap 'rm -rf "$STAGED"' EXIT
ditto "$APP" "$STAGED"
# Prozessname ist MuckeBaby, nicht der Anzeigename des Bundles.
pkill -x MuckeBaby 2>/dev/null || true
/usr/bin/swift - "$STAGED" "$DESTINATION" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if fileManager.fileExists(atPath: destination.path) {
    _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: source,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
    )
} else {
    try fileManager.moveItem(at: source, to: destination)
}
SWIFT
trap - EXIT

# Nach dem Kopieren erneut prüfen: erst dann ist die Installation belegt.
xcrun stapler validate "$DESTINATION"
spctl -a -t exec -vv "$DESTINATION" 2>&1 | tail -2

echo "INSTALL OK: $DESTINATION ($VERSION)"
