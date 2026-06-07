#!/usr/bin/env bash
# Baut aus einem 1024x1024-PNG ein macOS-.icns (alle Retina-Größen).
# Reproduzierbar + agent-steuerbar: Quelle und Ziel als Argumente.
#
# Aufruf:
#   ./make-icns.sh [SRC_PNG] [OUT_ICNS]
# Defaults: brushed s123 (eingecheckter Master) -> ../Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")"

# Default = eingecheckter Master (candidates/ ist gitignored).
SRC="${1:-app-icon-brushed-s123.png}"
OUT="${2:-../Resources/AppIcon.icns}"

[ -f "$SRC" ] || { echo "Quelle fehlt: $SRC" >&2; exit 1; }

# Temporäres .iconset-Verzeichnis mit allen von iconutil erwarteten Größen.
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

# Größe (px) -> Dateiname. @2x = Retina-Variante doppelter Auflösung.
gen() { sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null; }
gen 16    icon_16x16.png
gen 32    icon_16x16@2x.png
gen 32    icon_32x32.png
gen 64    icon_32x32@2x.png
gen 128   icon_128x128.png
gen 256   icon_128x128@2x.png
gen 256   icon_256x256.png
gen 512   icon_256x256@2x.png
gen 512   icon_512x512.png
gen 1024  icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "geschrieben: $OUT ($(du -h "$OUT" | cut -f1))"
