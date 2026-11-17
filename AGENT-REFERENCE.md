# Technische Arbeitsreferenz

## Linux-Port

Unter `linux/` liegt eine native C++17-/Qt-6-Widgets-Anwendung für Linux Mint 22
und CachyOS auf x86-64. Sie nutzt system-libVLC 3, einen ausschließlich eigenen
PulseAudio-/PipeWire-Pulse-Ausgabemonitor, FFmpeg für M4A-Exporte und
nlohmann::json für exakte UInt64-Austauschrevisionen. Der Browser ist keine
Laufzeitabhängigkeit. `docs/linux.md` beschreibt Einrichtung und Formatgrenzen.

Die Wurzelskripte wählen unter Linux `build-linux.sh`, `install-linux.sh` und
`release-linux.sh`. Installation erfolgt atomar im Benutzerpräfix, ohne Appstart;
Release erzeugt nur ein lokales Archiv. `Sources/Models.swift` bleibt auch für
den Linux-Bau die einzige Produktversionsquelle.

Linux-Daten liegen unter XDG/MuckeBaby; nicht mit den internen macOS-Dateien
zusammenlegen. Austausch ausschließlich über V1/V2/V3 mit Importvorschau.
Aufnahme und Puffer sind zunächst aus. Grenzen, Quellschutz und getrennte
Löschaktionen gelten auf beiden Plattformen. Keine persönliche Seed-Datei ins
Linux-Ressourcenbundle aufnehmen.

`ctest --test-dir build/linux --output-on-failure` prüft Daten, Protokolle,
Puffer, Songgrenzen, Installer und UI. Echte Audio-/Exportprüfungen in
`linux/tests/` brauchen einen isolierten Pulse-Server und explizites Opt-in;
keine Desktopaufnahme und keine realen Nutzerdaten verwenden. Decoderprofile
nur nach vollständigem PCM-Vergleich zulassen, nicht nach alleiniger
Zeitstempel- oder Kreuzkorrelationsprüfung.

## Bauen und testen

```bash
./build.sh
open "build/Mucke, Baby!.app"
MUCKE_SHOTS=/tmp/mucke-shots \
  "build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby"
```

`./build.sh` prüft Downloadhash, Kompilierung, Bundle, Ressourcen,
Lokalisierungen, Framework und Codesign. Ad-hoc ist nur für Entwicklung
zulässig; ein Release braucht die vollständige Kette.

Der direkte Hintergrundstart ist kein verlässlicher Audiotest: LaunchServices
und Vordergrund-App-Status können beeinflussen, ob VLC einen CoreAudio-Ausgang
öffnet. Wiedergabe-End-to-end über `open` oder Finder starten und Logs gezielt
auswerten. Automatische Screenshots prüfen Layout und Theme, nicht hörbares Audio.

Änderungsabhängige Gates:

- Models/Store: temporäre Persistenzfixtures, Migration und fehlerhafte JSON-
  Eingaben.
- Playlist/ICY: lokale HTTP-Fixtures für Format, Redirect, Größenlimit,
  Kodierung, Metadatenintervalle und Abbruch.
- Player: Senderwechsel, später Stop, Streamende und Cleanup aller Verbindungen.
- Recorder/Exporter: Default aus, Disk-Gate, 24-h-Rollover, Dateikollision,
  Recovery, Sanitizing, Export und Löschgrenzen.
- AudioTap/Visualizer: Thread-Sicherheit, Nullbreite, echte Stille, normalisierte
  Pegel sowie Screenshots aller Themes.
- UI/Theme: alle sieben automatischen Screenshots bei mindestens normaler und
  schmaler Breite; Standardtheme in Hell und Dunkel.
- Lokalisierung: deutsche und englische `.strings` vollständig; neue sichtbare
  Texte in beiden Sprachen.
- Build/Dependency: frischer Vendor-Cache, Hash und Bundle-Start.

`Tests/run-tests.sh` kompiliert den Headless-Harness (`Tests/ReviewHarness.swift`,
reiner Foundation-Code ohne VLCKit/SwiftUI) und führt ihn aus: URL-Policy und
Log-Redaktion, Playlist-Resolver gegen lokale HTTP-Fixtures, Recorder-Index- und
Löschgrenzen, Preview-Koordinator. Er ist das Pflicht-Gate für Änderungen an
diesen Pfaden.

`Tests/fleet-rules.sh` hält die beiden Fleet-Regeln vom 2026-08-03 fest: Nach
`/Applications` gelangt nur ein Bundle mit angeheftetem Notary-Ticket (Ad-hoc
bleibt in `build/`), und kein absoluter Pfad des Build-Rechners darf im
ausgelieferten Bundle landen. Der Test liest nur Quellen und baut, signiert und
installiert nichts. Diese Prüfung nie dadurch „belegen", dass der echte
Installationsweg gegen `/Applications` läuft — das ersetzt die installierte
App.

Darüber hinaus besitzt das Repo noch keine ausreichende
automatisierte Unit-Test-Suite. Neue kritische Logik nicht nur durch Build und
Screenshots absichern; testbare Komponenten schrittweise in den Harness oder
weitere Swift-Tests auslagern.

## Release

Drei Einstiegspunkte: `build.sh` baut nur, `./install.sh` installiert notarisiert
nach `/Applications`, `./release.sh` packt das DMG (installiert nie). Beide
heften zuerst der App selbst ein Ticket an — bei einer Sparkle-App doppelt
wichtig, weil das Update die neue Version selbst entpackt. Profilname aus
`NOTARY_PROFILE` oder `git config muckeBaby.notaryProfile`.

`wrappers/sign-and-release.sh` (Unterbau von `release.sh`) signiert Framework und
App inside-out, notarisiert die App, erzeugt ein DMG, notarisiert, stapelt und
prüft es. Identität und Notary-Profil kommen aus Umgebung bzw. Schlüsselbund;
keine Kontodaten in Argumenten, Skripten oder Logs. `--no-finder-layout`
überspringt den fokusraubenden AppleScript-Schritt (nicht für echte Releases).

Der Standardlauf erzeugt nur ein lokales DMG. Veröffentlichung, Tag und Upload
sind ausschließlich über den ausdrücklichen `--publish`-Pfad und nur nach
konkreter Freigabe zulässig. Ein bereits veröffentlichtes Release wird dabei nie
überschrieben: Der Lauf bricht ab und verlangt eine neue Version, weil der
Sparkle-Feed sonst weiter Länge und Signatur des alten DMG nennt. Einziger
Ausnahmeweg ist der manuelle Start des Appcast-Workflows für ein unverändertes
Release (`docs/sparkle-release.md`). Vorher:

- Arbeitsbaum und Version/Changelog konsistent;
- öffentliche Seed-Liste im Bundle, keine private Senderliste;
- README, CHANGELOG und THIRD-PARTY aktuell;
- Signatur, Notarisierung, Stapler und Gatekeeper grün;
- DMG auf einem sauberen Nutzerpfad öffnen und App starten;
- ausgehenden Stand auf private Pfade, Hosts, Kontakte, Credentials, interne
  Assistentenformulierungen und unlizenzierte Assets prüfen.

`AppInfo.version` ist die einzige Version. Build und Release extrahieren sie und
spiegeln sie in Info.plist, DMG-Name, Tag und Release Notes. Reine AGENTS-/Doku-
Reorganisation erfordert keinen Produktversions-Bump.
