#!/usr/bin/env bash
# Baut "Mucke, Baby!.app" aus den Swift-Quellen — ohne Xcode-Projekt, nur swiftc.
# Audio-Engine: VLCKit (libVLC) -> spielt ALLE Codecs (mp3/aac/ogg/opus/flac…).
# Das VLCKit-Framework wird einmalig heruntergeladen (nach .vendor/, gitignored)
# und ins .app-Bundle kopiert. Komplett kommandozeilen-/agent-steuerbar.
set -euo pipefail
cd "$(dirname "$0")"

# Bundle heisst "Mucke, Baby!" (Anzeigename); Binary/Prozessname "MuckeBaby"
# (sichtbar z.B. im Aktivitaetsmonitor). Bundle-ID bleibt aus Kontinuitaet de.danielmuller.macradio.
EXE="MuckeBaby"
BUNDLE="Mucke, Baby!"
BUILD="build"
APPDIR="$BUILD/$BUNDLE.app"
MODULE_CACHE="$BUILD/module-cache"   # projektlokal: funktioniert auch in Sandbox/Agent-Umgebungen
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.2"   # CoreAudio Process-Tap (AudioTap) braucht 14.2+

# --- VLCKit beschaffen (einmalig) ---------------------------------------
VENDOR=".vendor"
XCFW="$VENDOR/VLCKit.xcframework"
FWDIR="$XCFW/macos-arm64_x86_64"          # -F zeigt hierauf (enthaelt VLCKit.framework)
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz"

if [ ! -d "$FWDIR/VLCKit.framework" ]; then
  echo "Lade VLCKit (einmalig, ~84 MB) …"
  mkdir -p "$VENDOR"
  ( cd "$VENDOR"
    curl -L --fail -o vlckit.tar.xz "$VLCKIT_URL"
    tar -xJf vlckit.tar.xz
    mv "VLCKit - binary package/VLCKit.xcframework" ./VLCKit.xcframework
    rm -rf "VLCKit - binary package" vlckit.tar.xz )
fi

# --- Bundle-Geruest -----------------------------------------------------
rm -rf "$BUILD"/*.app          # alte Bundles (auch frueheres MacRadio.app) weg
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Frameworks" "$MODULE_CACHE"

echo "Kompiliere …"
swiftc -O -parse-as-library \
  -target "$TARGET" -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -F "$FWDIR" -framework VLCKit \
  -framework SwiftUI -framework AppKit -framework CoreAudio \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift \
  -o "$APPDIR/Contents/MacOS/$EXE"

cp Resources/Info.plist "$APPDIR/Contents/Info.plist"

# Versionsnummer aus Models.swift (AppInfo.version = einzige Quelle) in die
# Bundle-Info.plist spiegeln, damit Finder/„Über"-Dialog dieselbe Version zeigen.
VERSION=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' Sources/Models.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APPDIR/Contents/Info.plist" >/dev/null 2>&1
fi

# App-Icon (Squircle, speaker-cone). Default s123; tauschbar via Resources/AppIcon.icns.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"
fi

# Kuratierte Genre-Listen (Punkt 1) ins Bundle.
if [ -d Resources/genre-lists ]; then
  cp -R Resources/genre-lists "$APPDIR/Contents/Resources/"
fi

# Theme-Texturen (Theme-System) ins Bundle — falls vorhanden.
# Loader: Theme.image() sucht in Contents/Resources/themes/<id>/<datei>.png.
if [ -d Resources/themes ]; then
  cp -R Resources/themes "$APPDIR/Contents/Resources/"
fi

# Persoenliche Seed-Liste verwenden, falls vorhanden — sonst generisches Beispiel.
if [ -f Resources/seed-stations.json ]; then
  cp Resources/seed-stations.json "$APPDIR/Contents/Resources/seed-stations.json"
elif [ -f Resources/seed-stations.example.json ]; then
  cp Resources/seed-stations.example.json "$APPDIR/Contents/Resources/seed-stations.json"
fi

# Lokalisierungen ins Bundle (de = Entwicklungssprache, en = Englisch). SwiftUI lokalisiert
# String-Literale automatisch ueber Localizable.strings; InfoPlist.strings lokalisiert die
# Berechtigungstexte (z.B. NSAudioCaptureUsageDescription).
for lang in de en; do
  if [ -d "Resources/$lang.lproj" ]; then
    mkdir -p "$APPDIR/Contents/Resources/$lang.lproj"
    cp Resources/"$lang".lproj/*.strings "$APPDIR/Contents/Resources/$lang.lproj/"
  fi
done

# VLCKit-Framework ins Bundle (Install-Name nutzt @loader_path/../Frameworks).
echo "Bündle VLCKit …"
cp -R "$FWDIR/VLCKit.framework" "$APPDIR/Contents/Frameworks/"

# Signieren inside-out (erst Framework, dann App). Wenn ein Developer-ID-Zertifikat da ist,
# damit + Hardened Runtime signieren: dann bleibt die einmal erteilte Audio-Aufnahme-Erlaubnis
# (TCC) ueber REBUILDS erhalten — TCC schluesselt auf Team-ID + Bundle-ID, nicht auf den bei
# jedem ad-hoc-Build wechselnden cdhash (sonst fragt macOS staendig neu). Kein --timestamp
# (braucht Netz, fuer lokale Builds unnoetig; die Release-Signatur in wrappers/ stempelt). Sonst
# ad-hoc-Fallback. VLCKit wird mit derselben Identitaet signiert (Library-Validation).
DEVID="Developer ID Application: Daniel Mueller (9QSWKSR4NQ)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVID"; then
  codesign --force --options runtime --sign "$DEVID" "$APPDIR/Contents/Frameworks/VLCKit.framework" >/dev/null 2>&1 || true
  codesign --force --options runtime --sign "$DEVID" "$APPDIR" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$APPDIR/Contents/Frameworks/VLCKit.framework" >/dev/null 2>&1 || true
  codesign --force --sign - "$APPDIR" >/dev/null 2>&1 || true
fi

echo "Fertig: $APPDIR"
