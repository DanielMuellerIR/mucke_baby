#!/bin/bash
# Gemeinsame Notarisierungs-Helfer für install.sh und wrappers/sign-and-release.sh.
# Wird gesourct, nicht ausgeführt. Credential-Werte bleiben ausschließlich im
# macOS-Schlüsselbund; hier steht nur der Profil-NAME.

# Profilnamen bestimmen: Umgebung schlägt clone-lokale Git-Konfiguration.
# Kein fester Default — ein eingecheckter Name existiert auf fremden Macs nicht
# und ließe den Lauf erst nach dem Bauen scheitern. Keychain-Profile sind ohnehin
# pro Mac lokal und werden nicht synchronisiert.
require_notary_profile() {
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_PROFILE="$(git config --local --get muckeBaby.notaryProfile 2>/dev/null || true)"
    fi
    if [[ -z "$NOTARY_PROFILE" ]]; then
        echo "FEHLER: Kein Notary-Profil bekannt." >&2
        echo "Entweder NOTARY_PROFILE setzen oder einmalig für diesen Clone:" >&2
        echo "  git config --local muckeBaby.notaryProfile <profil>" >&2
        echo "Das Profil selbst einmal pro Mac anlegen:" >&2
        echo "  xcrun notarytool store-credentials <profil> --apple-id <apple-id> --team-id <team-id>" >&2
        return 2
    fi
    export NOTARY_PROFILE

    # Nur ein echter Aufruf erkennt, ob das Profil auf diesem Mac benutzbar ist.
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "FEHLER: Das Notary-Profil '$NOTARY_PROFILE' ist auf diesem Mac nicht verwendbar." >&2
        echo "Über SSH ist der Login-Schlüsselbund gesperrt — dann in einer lokalen" >&2
        echo "Terminalsitzung erneut versuchen." >&2
        return 2
    fi
}

# Team-ID/Identitaet ueberschreibbar (CI/anderer Account); Default als Fallback.
NOTARY_TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
NOTARY_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($NOTARY_TEAM_ID)}"

# Das ganze Bundle mit Developer ID signieren — innere Frameworks ZUERST, dann
# die App. build.sh signiert zwar auch schon, aber ohne Zeitstempel; für die
# Notarisierung wird hier vollständig nachsigniert.
# --options runtime: Hardened Runtime (Pflicht für Notarisierung).
# --timestamp:       Apple-Zeitstempel → Signatur bleibt nach Zert-Ablauf gültig.
# VLCKit muss mit UNSERER Team-ID signiert sein, sonst scheitert unter Hardened
# Runtime die Library-Validation beim Laden.
# Sparkles innere Helfer (Autoupdate, Updater.app) brauchen ebenfalls unsere
# Team-ID und werden von innen nach aussen signiert — sonst lehnt die
# Notarisierung ab („binary is not signed with a valid Developer ID").
# Kein --deep: verschachtelte Ziele haben eigene Regeln.
sign_app_chain() {
    local app="$1"
    local sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
    local vlckit_fw="$app/Contents/Frameworks/VLCKit.framework"

    if ! security find-identity -v -p codesigning | grep -Fq "$NOTARY_IDENTITY"; then
        echo "FEHLER: Signing-Identität nicht gefunden: $NOTARY_IDENTITY" >&2
        security find-identity -v -p codesigning >&2
        return 1
    fi

    echo "==> Signiere Sparkle.framework (inside-out)"
    # Die XPC-Services stecken NUR in der Binaerdistribution (SwiftPM-Builds haben
    # sie nicht) — ohne eigene Signatur lehnt die Notarisierung ab (belegt:
    # Submission c0dfe666, 2026-07-17). Downloader.xpc ist gesandboxt und braucht
    # seine mitgelieferten Entitlements (--preserve-metadata), sonst bricht der
    # Update-Download zur Laufzeit.
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
        --sign "$NOTARY_IDENTITY" "$sparkle_fw/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$sparkle_fw/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$sparkle_fw/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$sparkle_fw/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$sparkle_fw"

    echo "==> Signiere VLCKit.framework"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$vlckit_fw"

    echo "==> Signiere App-Bundle"
    codesign --force --options runtime --timestamp --sign "$NOTARY_IDENTITY" "$app"

    echo "==> Verifiziere Signatur"
    codesign --verify --strict --deep --verbose=2 "$app"
    codesign -dvv "$app" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true
}

# App-Bundle notarisieren und das Ticket anheften. notarytool nimmt kein nacktes
# .app entgegen, deshalb der Umweg über ein ZIP. Das angeheftete Ticket ist der
# eigentliche Punkt: Damit startet die App auch dann ohne Gatekeeper-Meckern,
# wenn jemand sie aus dem DMG herauszieht oder offline ist.
notarize_app() {
    local app="$1"
    local archive
    archive="$(mktemp -d)/MuckeBaby.zip"

    if ! codesign --verify --strict "$app" >/dev/null 2>&1; then
        echo "FEHLER: '$app' ist nicht gültig signiert — Notarisierung sinnlos." >&2
        return 1
    fi
    if codesign -dvv "$app" 2>&1 | grep -q '^Signature=adhoc$'; then
        echo "FEHLER: '$app' ist nur ad-hoc signiert. Für die Notarisierung ist eine" >&2
        echo "Developer-ID-Signatur nötig." >&2
        return 1
    fi

    echo "=== Notarisiere App (Profil: $NOTARY_PROFILE) ==="
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl -a -t exec -vv "$app" 2>&1 | tail -2
    rm -rf "$(dirname "$archive")"
}
