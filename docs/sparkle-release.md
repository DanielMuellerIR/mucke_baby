# Sparkle-Updates veröffentlichen

Mucke, Baby! bindet Sparkle 2.9.4 als gepinnte Binärdistribution ein (`build.sh`
lädt sie SHA-256-geprüft nach `.vendor/`, kein SwiftPM). Die App prüft den Feed
unter `https://danielmuellerir.github.io/mucke_baby/appcast.xml`, lädt das DMG
aus dem zugehörigen GitHub Release und installiert ausschließlich nach
Zustimmung des Nutzers.

Die erste Sparkle-fähige Version ist der einmalige Bootstrap: Vorgängerversionen
enthalten keinen Updater und können sie nicht selbst finden. Bestehende
Installationen müssen diese Version einmal manuell per DMG installieren; erst
danach greifen automatische Updates.

Zwei voneinander unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Sparkle-Ed25519-Signatur für das Update-Archiv sowie den Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Der projektspezifische Schlüssel liegt lokal im Login-Schlüsselbund des
Release-Rechners unter dem Sparkle-Account
`io.github.danielmuellerir.muckebaby`. Nur sein
öffentlicher Gegenpart steht als `SUPublicEDKey` in `Resources/Info.plist`.
Jede App hat ihr eigenes Schlüsselpaar; Schlüssel nie zwischen Projekten teilen.

## Einmalige GitHub-Einrichtung (erledigt 2026-07-17)

1. Pages-Quelle des Repos auf **GitHub Actions** gestellt
   (`gh api -X POST repos/DanielMuellerIR/mucke_baby/pages -f build_type=workflow`).
2. Privater Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegt
   (`generate_keys -x <datei>` → `gh secret set … < datei` → Datei mit `rm -P`
   entfernt; der Schlüssel stand nie in argv oder Logs).
3. Offen: den Schlüssel zusätzlich verschlüsselt sichern (Login-Schlüsselbund
   synct nicht über iCloud). Geht er verloren, ist eine kontrollierte
   Schlüsselrotation über ein Developer-ID-signiertes DMG nötig.

## Ablauf pro Release

1. `AppInfo.version` in `Sources/Models.swift` erhöhen (einzige Versionsquelle;
   `build.sh` spiegelt sie in `CFBundleShortVersionString` UND `CFBundleVersion`
   — Sparkle vergleicht nur `CFBundleVersion`, sie muss monoton steigen) und
   `CHANGELOG.md` aktualisieren.
2. `bash wrappers/sign-and-release.sh` — signiert Sparkles Helfer
   (`Autoupdate`, `Updater.app`) und beide Frameworks von innen nach außen mit
   derselben Developer-ID wie die App, erzeugt das DMG, notarisiert und stapelt.
3. Nur nach ausdrücklicher Freigabe: `--publish` setzt das Tag, erstellt das
   GitHub Release und lädt genau ein DMG hoch.
4. `.github/workflows/publish-appcast.yml` läuft beim Veröffentlichen des
   Releases: lädt dieses DMG, holt die gepinnten Sparkle-Werkzeuge
   (SHA-256-geprüft, derselbe Pin wie `build.sh`), erzeugt mit
   `generate_appcast` einen signierten Feed (Schlüssel via stdin aus dem
   Secret), bettet die Release Notes ein und deployt `appcast.xml` über Pages.
5. Workflow und anschließend
   `https://danielmuellerir.github.io/mucke_baby/appcast.xml` prüfen. Im
   App-Menü **„Nach Updates suchen …"** muss eine ältere, signiert installierte
   und bereits Sparkle-fähige Testversion das neue Release finden, installieren
   und neu starten. Für den Bootstrap-Test: einen signierten Test-Build mit
   kleinerer `CFBundleVersion` und demselben Schlüssel verwenden — echte
   Vorgängerversionen ohne Sparkle taugen nicht als Testkandidat.

Der Workflow kann für ein bereits veröffentlichtes Tag manuell gestartet werden
(`workflow_dispatch`, Input `tag`). Er erwartet genau ein `*.dmg` im Release.
Der Feed führt nur das aktuelle Vollupdate; Delta-Updates sind bewusst
deaktiviert (`--maximum-deltas 0`), bis der Pages-Workflow mehrere historische
Archive mit ihren jeweiligen Download-URLs verwaltet.

Hinweis für Screenshot-/Testläufe: Mit gesetztem `MUCKE_SHOTS` startet der
Updater nicht (kein Netz-Check, kein Dialog in den Theme-Fotos) — siehe
`Sources/UpdaterController.swift`.
