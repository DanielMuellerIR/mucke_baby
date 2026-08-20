#!/usr/bin/env bash
# Tests/fleet-rules.sh — prueft die beiden fleetweiten Regeln vom 2026-08-03 an der QUELLE.
#
#   Regel 1  In /Applications gehoeren nur Bundles mit angeheftetem Notary-Ticket.
#            install.sh muss das Ticket verlangen, BEVOR es das erste Mal nach
#            /Applications schreibt. Ad hoc gebaut wird nur in build/.
#   Regel 2  Kein absoluter Pfad des Build-Rechners im ausgelieferten Bundle.
#
# Der Test liest nur Dateien. Er baut nichts, signiert nichts, notarisiert nichts
# und fasst /Applications nicht an — genau das ist der Punkt: Ein Test, der zum
# Beleg den echten Installationsweg starten muesste, wuerde dabei die installierte
# App loeschen und ersetzen. Er waere selbst die Gefahr, vor der die Regel schuetzt.
#
# Aufruf:  bash Tests/fleet-rules.sh
# Exit 0 = alle Pruefungen gruen.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1" >&2; fail=1; }

# Filtert reine Kommentarzeilen (# in Shell, // in Swift) mit beliebigem Whitespace
# (Leerzeichen/Tabs) vor dem Kommentarzeichen aus Zeilenlisten mit Zeilennummern.
filter_comments() {
    grep -vE '^([^:]+:)?[0-9]+:[[:space:]]*(#|//)'
}

# Zeilennummer des ersten Vorkommens eines festen Textes in einer Datei —
# reine Kommentarzeilen zaehlen nicht mit. Sonst koennte eine Begruendung im
# Kopfkommentar die Reihenfolge der echten Befehle vortaeuschen.
first_line() {   # $1 = Datei, $2 = fester Text
    grep -nF -- "$2" "$1" | filter_comments | head -1 | cut -d: -f1
}

echo "1. Regel 1: Ticket vor dem ersten Schreiben nach /Applications"

notarize_line="$(first_line install.sh 'notarize_app "$APP"')"
# Erster Schreibzugriff in /Applications ist das Anlegen des Staging-Pfads.
stage_line="$(first_line install.sh 'STAGED="/Applications/')"
if [ -z "$notarize_line" ] || [ -z "$stage_line" ]; then
    bad "install.sh hat sich strukturell geaendert — Test veraltet, bitte anpassen"
else
    [ "$notarize_line" -lt "$stage_line" ] \
        && ok "notarize_app laeuft vor dem ersten Schreiben nach /Applications" \
        || bad "install.sh schreibt nach /Applications, bevor notarisiert wurde"
fi

# Reihenfolge allein genuegt nicht: Ein `notarize_app "$APP" || true` stuende an
# derselben Stelle, liefe aber trotz Fehlschlag weiter. Deshalb zusaetzlich
# belegen, dass der Fehler nicht abgefangen wird und das Skript bei Fehlern
# ueberhaupt abbricht.
if grep -nE 'set \+[eo]' install.sh | filter_comments | grep -q .; then
    bad "install.sh schaltet die Fehlerbehandlung ab (set +e)"
fi
notarize_traps="$(grep -nE 'notarize_app "\$APP"[[:space:]]*(\|\|[[:space:]]*(true|:)|;|&&[[:space:]]*(true|:))' install.sh \
    | filter_comments || true)"
if [ -n "$notarize_traps" ]; then
    bad "notarize_app-Fehler wird in install.sh ignoriert statt weitergereicht"
else
    ok "notarize_app-Fehler wird in install.sh nicht ignoriert"
fi
grep -qE '^set -euo pipefail$' install.sh \
    && ok "install.sh bricht bei Fehlern ab (set -e)" \
    || bad "install.sh hat kein 'set -euo pipefail' mehr — ein Notary-Fehler liefe weiter"

grep -qF 'require_notary_profile' install.sh \
    && ok "install.sh verlangt ein Notary-Profil" \
    || bad "install.sh verlangt kein Notary-Profil mehr"
grep -qF 'Signature=adhoc' notarize-lib.sh \
    && ok "notarize-lib.sh lehnt ad-hoc signierte Bundles ab" \
    || bad "notarize-lib.sh prueft nicht mehr auf ad-hoc-Signatur"
grep -qF 'stapler validate "$app"' notarize-lib.sh \
    && ok "notarize-lib.sh belegt das angeheftete Ticket" \
    || bad "notarize-lib.sh prueft das angeheftete Ticket nicht mehr"

# Das Bauziel darf nicht aus der Umgebung kommen: build.sh loescht `$BUILD/*.app`
# per rm -rf. Ein umbiegbarer Wert koennte damit die installierte App treffen und
# durch einen ad-hoc signierten Build ersetzen.
grep -qE '^BUILD="build"$' build.sh \
    && ok "build.sh baut fest nach build/" \
    || bad "build.sh baut nicht mehr fest nach build/ — Bauziel darf nicht umbiegbar sein"

echo
echo "2. Regel 2: keine absoluten Build-Mac-Pfade im ausgelieferten Bundle"

# Reine Kommentarzeilen ausnehmen, sonst schlaegt der Test an der Begruendung an.
# Das Ergebnis wird eingesammelt statt in `grep -q` gepipet: ein `grep -q` am Ende
# einer Pipeline schliesst die Leitung nach dem ersten Treffer, der Erzeuger stirbt
# an SIGPIPE, und `pipefail` machte daraus faelschlich einen Fehlschlag.
code_matches() {   # $1 = erweiterter regulaerer Ausdruck
    grep -rnE --include='*.swift' "$1" Sources 2>/dev/null \
        | filter_comments
}

# `#filePath`/`#file` setzen den absoluten Quellpfad des Build-Rechners als
# Zeichenkette ins Binary.
hits="$(code_matches '#filePath|#file[^P]')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    bad "#filePath/#file in Sources — der Quellpfad des Build-Macs landet im Binary"
else
    ok "kein #filePath/#file in Sources"
fi

# `Bundle.module` waere der zweite Weg: SwiftPM baut in den dafuer erzeugten Zugriff
# den absoluten .build-Pfad des Build-Macs ein. build.sh nutzt reines swiftc ohne
# Ressourcen-Bundle; die Pruefung haelt das fest.
hits="$(code_matches 'Bundle\.module')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    bad "Bundle.module in Sources — bringt den absoluten .build-Pfad ins Binary"
else
    ok "kein Bundle.module in Sources"
fi

# Direkte Probe am eigenen Binary, falls schon gebaut. Geprueft wird nur unser
# Programm, nicht die mitgelieferten Fremd-Frameworks.
BIN="build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby"
artifact_skipped=0
if [ -f "$BIN" ]; then
    home_paths="$(strings -a "$BIN" | grep -F "$HOME/")"
    if [ -n "$home_paths" ]; then
        printf '%s\n' "$home_paths" | sed 's/^/    /' >&2
        bad "gebautes Binary enthaelt Pfade aus dem Heimatverzeichnis"
    else
        ok "gebautes Binary enthaelt keine Pfade aus dem Heimatverzeichnis"
    fi
else
    # Ein fehlender Pruefgegenstand ist kein Erfolg. Ohne Binary laeuft der Test
    # weiter (er baut bewusst nichts), meldet den Verzicht aber im Ergebnis —
    # und mit FLEET_RULES_REQUIRE_ARTIFACT=1 (Release/CI) ist er ein Fehlschlag.
    if [ "${FLEET_RULES_REQUIRE_ARTIFACT:-0}" = "1" ]; then
        bad "Binary fehlt, Artefaktprobe unmoeglich (erst 'bash build.sh')"
    else
        artifact_skipped=1
        echo "  --   Binary nicht vorhanden; Probe uebersprungen (erst 'bash build.sh')"
    fi
fi

echo
if [ "$fail" != "0" ]; then
    echo "fleet-rules: FEHLGESCHLAGEN" >&2
    exit 1
elif [ "$artifact_skipped" = "1" ]; then
    echo "fleet-rules: Quellregeln OK — Artefaktprobe uebersprungen (kein Binary)"
else
    echo "fleet-rules: OK"
fi
