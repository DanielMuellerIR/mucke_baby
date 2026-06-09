# Mucke, Baby! — Projektfakten

(Anzeigename „Mucke, Baby!"; Binary/Bundle-ID/Datenordner bleiben aus Kontinuität „MacRadio"
bzw. `de.danielmuller.macradio`.)

Stand: 2026-06-07

Nativer macOS-Webradio-Player (SwiftUI + VLCKit), Nachbau der Kernfunktionen
des Linux-Mint-Applets **Radio++**.

## Vision / Zweck

Schlanker Radioplayer als normales Fenster-App. Sender abspielen, verwalten,
suchen. Menüleisten-Modus optional. Privat für Daniel; ggf. später GitHub-Release.

## Tech-Stack

- Swift 6.x, SwiftUI (App-Lifecycle).
- **Audio-Engine: VLCKit (libVLC)** — spielt ALLE Codecs (mp3/aac/**ogg/opus/flac**…).
  Framework `VLCKit.xcframework` (~84 MB) wird von `build.sh` einmalig nach `.vendor/`
  geladen (gitignored) und ins `.app`-Bundle kopiert (`Contents/Frameworks/`, ad-hoc signiert).
- **Kein Xcode-Projekt.** Build per `swiftc` → manuelles `.app`-Bundle (`build.sh`).
  Nur Command Line Tools nötig. Voll kommandozeilen-/agent-steuerbar.
- Ziel: macOS 14+, arm64.

## Bauen & Starten (Headless/CLI)

```bash
./build.sh          # kompiliert -> build/MacRadio.app
./run.sh            # baut + startet
open build/MacRadio.app
# Direktstart mit Logs (zum Debuggen):
build/MacRadio.app/Contents/MacOS/MacRadio
```

## Architektur (Sources/)

- `Models.swift` — `Station`, `SeedStation`, `AppInfo.version`.
- `Store.swift` — Senderliste laden/speichern, CRUD, Favorit, Seed-Import, **Genre-Listen-Import**.
- `RadioPlayer.swift` — VLCKit-Wrapper: play/stop, Status, Volume. „Spielt"-Signal über
  `mediaPlayerTimeChanged` (state bleibt bei Live-Streams oft auf `.buffering` hängen).
- `ICYMetadataReader.swift` — liest den Now-Playing-Titel (ICY `StreamTitle`) per eigener
  Zweitverbindung (`Icy-MetaData:1`, `icy-metaint`). **VLCKit liefert die Live-Metadaten nicht.**
- `SongHistory.swift` — Wiedergabeverlauf (`verlauf.json`): pro Titel Eintrag mit Start/Ende.
- `PlaylistResolver.swift` — löst `.pls`/`.m3u`/`.asx`/`.xspf`/`Tune.ashx` zur Stream-URL auf
  (VLCMediaPlayer spielt Playlist-Container nicht selbst ab).
- `MacRadioApp.swift` — `@main`, Szenen (Fenster + optionaler `MenuBarExtra`), `ContentView`,
  `NowPlayingBar` (markier-/kopierbar), Verlaufs-Panel-Verdrahtung.
- `HistoryPanel.swift` — ausklappbares „Verlauf"-Panel rechts.
- `GenreListsView.swift` — Import-Dialog für kuratierte Genre-Listen.
- `Views.swift` — Sender-Edit, Einstellungen, radio-browser-Suche, Menüleisten-Inhalt.
- `Theme.swift` — **Theme-System** (Contract): `ThemeID`/`Theme`/`ThemePalette`/`ThemeFonts`,
  7 Theme-Definitionen, `Color(hex:)`, `EnvironmentValues.theme`, Textur-Loader.
- `ThemedComponents.swift` — wiederverwendbare Theme-Primitive: `ThemedSurface`
  (+ prozedurale Material-Texturen via `Canvas`), `VisualizerView` (waveform/VU/fabric/
  midiNotes/bars, TimelineView-animiert), `KnobView`, `LEDDot`, `SectionHeader`, `neonGlow`.
- `ScreenshotDebug.swift` — **nur** bei Env `MUCKE_SHOTS=<dir>` aktiv: schaltet beim Start
  durch alle Themes und fotografiert das eigene Fenster (ohne Screen-Recording-Recht). Sonst No-Op.

## Daten / Persistenz

- Senderliste: `~/Library/Application Support/MacRadio/stations.json`
  (von Hand editierbar). Erstbefüllung aus gebündelter `seed-stations.json`.
- Wiedergabeverlauf: `~/Library/Application Support/MacRadio/verlauf.json`.
- Lautstärke / Autostart / Menüleisten-Modus / Verlauf-Panel: UserDefaults (`@AppStorage`).
- Kuratierte Genre-Listen: gebündelt unter `Resources/genre-lists/` (manifest + je Genre eine JSON).

## Wichtige Entscheidungen / Stolpersteine

- **Seed-Daten:** `Resources/seed-stations.json` = personalisierte Sender-Liste (**gitignored**,
  nicht veröffentlichen). `Resources/seed-stations.example.json` = generische Default-Liste
  für eine GitHub-Release. `build.sh` nimmt die persönliche, falls vorhanden, sonst das Beispiel.
- **Favorit + Autostart:** „Hardstyle radio Italy" steht oben (Wunsch), ist aber **tot**: der
  zeno.fm-Mount `q86g2sqwn18uv` liefert konstant HTTP 401 (Mount existiert, Metadata-API antwortet —
  Audio geoblockt/gesperrt; radio-browser meldet ihn fälschlich OK). Entscheidung 2026-06-06:
  Eintrag bleibt oben/klickbar zum Wiederholen, **Autostart-Favorit = „A.D.M. Hardstyle Radio"**
  (torontocast, eigener Sender, im Durchsatztest stabil ~247 KB/3s). Autostart-Schalter in den
  Einstellungen. Hinweis: „I love Hardstyle" (iloveradio21.mp3) lieferte zeitweise 0 Bytes
  (drosselt nach vielen Verbindungen) — daher nicht als Autostart gewählt.
- **Tote/gesperrte Sender im Import:** „Hardstyle radio Italy" (401), „Tits.FM" (403). Bleiben in
  der Liste; können in der Bearbeiten-Ansicht gelöscht werden.
- **HTTP-Streams:** Info.plist setzt `NSAllowsArbitraryLoads` — viele Sender sind http.
- **Alle Codecs via VLCKit** — inkl. ogg/opus (z. B. „Hirschmilch Progressive", „RainWave Chiptune").
  Frühere AVFoundation-Engine konnte das nicht; deshalb der Wechsel (2026-06-07).
- **„Spielt"-Erkennung:** `VLCMediaPlayer.state` bleibt bei Live-Streams oft auf `.buffering`
  hängen, obwohl Audio läuft → als playing gilt das erste `mediaPlayerTimeChanged`-Event.
- **Now-Playing:** VLCKit gibt den ICY-`StreamTitle` NICHT über `metaData` heraus (immer leer,
  `title` = nur Mount-Name) → eigener `ICYMetadataReader` liest ihn aus einer Zweitverbindung.
- **VLC-`stop()` ist asynchron:** in `play()` NICHT aufrufen, sonst würgt der späte Stop die
  neue Wiedergabe ab (ewiges Puffern). `media=…`+`play()` ersetzt von selbst.
- **Headless-Test-Falle:** beim Direktstart der Binary im Hintergrund öffnet VLC keinen
  CoreAudio-Output → Endlos-Puffern. Über `open`/Finder (Vordergrund-App) läuft es. Tests
  daher per `open` + `log stream --predicate 'subsystem == "de.danielmuller.macradio"'`.

## Quelle des Imports

Exportdatei aus dem Radio++-Applet (Feld `tree.value` = die Sender; `last-volume` 77,
`last-url` = Hardstyle Italy). Exportpfad und Gerät: siehe Projekt-Wissensindex.

## Noch offen / bewusst weggelassen

- YouTube-Download (Radio++-Feature) — kein Radio-Kern, weggelassen.
- **App-Icon:** 8 Motive entworfen (`icons/motifs.md`); Erzeugung via
  `icons/generate-icons.sh` (mflux + Z-Image-Turbo, je 3 Varianten). Auswahl → `.icns` noch offen.
- **Release (signiert + notarisiert + DMG):** `bash wrappers/sign-and-release.sh` →
  baut, signiert mit Developer ID (Hardened Runtime), erzeugt DMG mit Hintergrundbild
  (`assets/generate-dmg-background.swift` → `assets/dmg-background.png`), notarisiert
  (Keychain-Profil `fftabsNotary`, env `NOTARY_PROFILE` überschreibbar) und stapelt das
  Ticket. Ergebnis: `build/Mucke-Baby-<version>.dmg`, Gatekeeper-clean. Voraussetzungen +
  Rezept: siehe Projekt-Wissensindex (`knowledge/macos-app-distribution.md`). **Audio-Reaktivität** nutzt
  einen CoreAudio Process-Tap (`NSAudioCaptureUsageDescription` in Info.plist) → beim ersten
  Start einmaliger macOS-Erlaubnis-Dialog (mit Developer-ID-Signatur dauerhaft gemerkt).
  **GitHub-Release (opt-in):** `bash wrappers/sign-and-release.sh --publish` setzt den
  git-Tag `vX.Y.Z`, erstellt das Release auf GitHub und lädt das DMG als Asset hoch.
  Release-Notes werden automatisch aus dem passenden `CHANGELOG.md`-Abschnitt gezogen.
  Ohne `--publish` läuft das Script wie bisher (nur lokales DMG, kein Push). Vor dem
  ersten `--publish`-Lauf: `gh auth status` prüfen + remote `github` muss zeigen auf
  `github.com/DanielMuellerIR/mucke_baby`.
- **Lizenzen/Fremdbestandteile: siehe [`THIRD-PARTY.md`](THIRD-PARTY.md).** Kurz: VLCKit
  = LGPL (Hinweis+Dynamic-Linking, erfüllbar); KI-Texturen/Icon (Z-Image-Turbo) = Apache-2.0
  (kommerziell frei); Fonts = System; Marke „Marshall"→„Stack" entschärft. Kommerziell möglich.

## Todos (später)

**→ Vollständige, priorisierte Liste in `TODO.md`** (Bugs, Visualizer, Recorder-Export-Test,
Icons, Release). Highlights: Verlauf-Platzhalter pro Session (sonst Mitschnitt ohne ICY-Titel
nicht erreichbar), Footer-Laufzeit, Visualizer (Metal/RetroOutrun/CoreAudio-Tap).

- **Alternativen recherchieren:** Welche Mac-Apps können Stream-Aufnahme + Song-Export, zu
  welchen Konditionen (Preis, nervig/nicht)? Daniel hat früher nichts Kostenloses ohne
  Gängelung gefunden — Stand der Dinge prüfen, Vergleich dokumentieren.

## Recorder (Aufnahme) — Design (Stand 2026-06-07, im Bau)

- **Default AN** (Daniel-Wunsch) — **README warnt** vor Dauer-Mitschnitt (Disk/Recht).
- **Kein Extra-Download:** der `ICYMetadataReader` lädt den Stream ohnehin komplett (für die
  Metadaten); beim Aufnehmen schreibt er die reinen Audio-Bytes (Metadaten-Blöcke raus) in eine
  Datei → direkt abspielbarer Roh-Dump, 0 zusätzliche Bandbreite.
- Eine Datei pro Sender-Session in `~/Music/MacRadio/Aufnahmen/`, Endung nach Codec; Rollover am
  nächsten Songwechsel nach 24 h. Index-JSON: Datei → Sender, Start/Ende, Codec.
- **Disk-Schutz:** Mitschnitt stoppt bei < 10 GB frei auf dem Volume (periodischer Check).
- **Retention:** Aufnahmen mit dem Verlauf-Alters-Cleanup mitlöschen.
- **Schnitt/Export on demand** aus dem Verlauf (Button + Drag&Drop), Fade-in/-out oder harter
  Cut. mp3/aac nativ via AVFoundation; ogg/opus nur mit ffmpeg (optional). Schnittgrenzen ±Sek.
  (ICY-Zeitstempel laufen dem Audio leicht nach).

## Theme-System (Stand 2026-06-07, v1.6.0)

7 umschaltbare Themes. Seit v1.7.x nutzen **ALLE** Themes dasselbe **3-Spalten-Layout**
(Stations | Stage+Visualizer | Verlauf) + eine **eigene Kopfleiste** (App-Titel groß +
Play/Stop + Laufzeit + Lautstärke + Aktions-Icons). Die native macOS-Toolbar/`NavigationStack`
wurde entfernt (`.windowStyle(.hiddenTitleBar)`), damit macOS 26 keine Glas-Kapseln um
Toolbar-Inhalte erzwingt (U1). Persistiert als `@AppStorage("selectedTheme")` = `ThemeID.rawValue`.
**Eine** theme-parametrisierte Codebasis, kein Fork.

- **`schlicht`** (Default, Anzeigename **„Standard"**) — minimalste, native-farbige Skin des
  3-Spalten-Layouts; dark/light folgt dem System. `colorScheme: nil` wird über einen
  `SystemAppearance`-Observer zu einem EXPLIZITEN Scheme aufgelöst (nie `nil` an
  `preferredColorScheme`, sonst hängt der Wechsel — Bug 6a). **Das ist der „Dark/Light-Mode".**
- **6 Design-Themes** (`acid`, `retro`, `fanzine`, `stack`, `danish`, `midi`) aus
  `design-proposal/*.png` — 3-Spalten-Layout + gemeinsame Kopfleiste (s. o.). Je eigene
  Palette/Fonts (nur macOS-Bordmittel: Mono/Serif/American Typewriter/Helvetica-thin/
  Noteworthy), Visualizer und prozedurale Material-Textur. `fanzine`+`danish` sind Light-Themes.
  **`stack`** war früher `marshall` — umbenannt wg. Markenrecht (Marshall = eingetragene
  Marke); Serif- statt Schreibschrift-Titel (kein Logo-Nachbau). Migration alter
  `selectedTheme`-Werte in `Theme.theme(raw:)`. Texturen unter `Resources/themes/stack/`.
- Spec: `design-proposal/THEME-PLAN.md`. **Material-Texturen per img2img** (mflux/
  Z-Image, `design-proposal/.asset-log.md`), gebündelt unter `Resources/themes/<id>/`,
  via `ThemedSurface` mit Kontrast-Scrim gezeigt. Fehlt eine PNG → **prozedurale Canvas-
  Textur als Fallback** (Code läuft also auch ohne Assets). Generierungsgerät + ssh-Stolperstein:
  siehe Projekt-Wissensindex.

**Themes visuell testen (agent-tauglich, ohne Screen-Recording-Recht):**
```bash
defaults write de.danielmuller.macradio selectedTheme -string schlicht   # in schlicht starten
MUCKE_SHOTS="$PWD/design-proposal/shots" "build/Mucke, Baby!.app/Contents/MacOS/MacRadio"
# -> design-proposal/shots/<theme>.png je Theme, App beendet sich selbst.
```

