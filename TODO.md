# Mucke, Baby! — Offene Todos

Stand: 2026-06-09 (v1.7.31). Projektfakten in `AGENTS.md`. Diese Liste = was noch offen ist.

## START HIER — nächste Session

Session 2026-06-07 (Teil 3) erledigt: **Mojibake-Fix** (ICY-Titel via Fallback-Kette
UTF-8→Shift-JIS/CP932→Latin-1), **Acid/Fanzine echtes Oszilloskop** (aus `audioTap.waveform`),
**Black-MIDI-Split** (Noten oben + Spektrum-Balken unten). Alle drei: Build grün +
Headless-Render geprüft, committet + auf internes Backup-Remote gepusht. Backup wieder online.

**Nur noch LIVE zu prüfen (nicht self-testbar):**
- Mojibake: Sender „Retro PC Game Music (JP)" → japanische Zeichen statt `?u?????`.
  (Verlauf-Altlasten bleiben garbled — nur NEUE Titel dekodieren korrekt.)
- Oszilloskop/MIDI-Balken: Audio-Hörbarkeit + Reaktivität am echten Material.
- VU-Nadel-Ballistik (v1.7.15): natürliches Gefühl, kein Sprung?

**OFFEN:**
5. **Feinschliff Audio-Kalibrierung** nach Geschmack (`rms*4.5`, Band-Frequenz-Tilt in
   AudioTap.swift) — jetzt am echten Material justieren (Visualizer stehen).

**ERLEDIGT (Session-Teil-3, v1.7.16–1.7.18):**
1. ✅ **Mojibake** — `ICYMetadataReader.parse` sucht ASCII-Marker in Roh-Bytes, dekodiert nur
   Titel-Bytes mit Fallback-Kette (UTF-8→Shift-JIS/CP932→Latin-1). Self-Test grün für alle 3.
   (`aacab57`, v1.7.16)
2. ✅ **VU-Nadel-Ballistik** (v1.7.15, 7064c0b) — Live-Check siehe oben.
3. ✅ **Acid/Fanzine Oszilloskop** — `WaveformVisualizer` zeichnet jetzt echtes Scope aus
   `audioTap.waveform` (zentrierte Mono-Kurve), Acid=Neon-Glow, Fanzine=gezackte Tinte,
   `!reactive`=Idle-Linie. Alte `WaveformShape`/`FanzineWaveShape` raus, `ScopeShape` neu.
   (`fa39be2`, v1.7.18)
4. ✅ **Black-MIDI-Split** — `MidiNotesVisualizer` gesplittet: oben Piano-Roll, Freiraum, unten
   schmaler Spektrum-Balken-Strip (`audioTap.bands`). Zeichnen in `drawNotes`/`drawBars`.
   (`4fa64b6`, v1.7.18)

**Bestätigt gut:** Klick-Fix, Ampel inline, Retro-Mess-Panel + Amber, GuitarAmp-Goldkopf +
3D-Knopf, Danish-Equalizer (echtes Spektrum), Audio-Reaktivität.
**Test-Falle:** Klicks/Ampel/Fenster-Drag/Audio-Hörbarkeit NICHT per Self-Screenshot prüfbar
→ live. Stage/VU/Header-Render + Audio-PEGEL (libVLC amem braucht keine Rechte!) SCHON
(MUCKE_SHOTS-Crop bzw. früher `/tmp`-Pegel-Dump).
**Mojibake-Test:** Sender „Retro PC Game Music (JP)" (in der Seed-Liste) reproduziert es sofort.

## Projekt-Umbenennung mac_radio → mucke_baby (offen, nächste Session)

Kurzname/Repo/Ordner sollen `mucke_baby` heißen (Anzeigename bleibt „Mucke, Baby!").
- [x] Backup-Repo umbenannt: `git/mac_radio.git` → `git/mucke_baby.git`, lokale
  Remote-URL auf internes Backup-Remote nachgezogen (2026-06-07).
- [ ] **Ordner** `~/git/mac_radio` → `~/git/mucke_baby` (macht Daniel nach Sessionende;
  im laufenden Betrieb ungesund). Git ist pfadunabhängig → danach keine Remote-Änderung nötig.
- [ ] **Entscheiden: interne Refs anfassen oder Kontinuität wahren?** EXE `MacRadio`,
  Bundle-ID `de.danielmuller.macradio`, Datenordner `~/Library/Application Support/MacRadio`,
  Aufnahmen `~/Music/MacRadio/`, `build/Mucke, Baby!.app`. **Achtung:** Bundle-ID/Datenordner
  ändern = UserDefaults + `stations.json`/`verlauf.json` + Aufnahmen verlieren (außer Migration).
  Empfehlung: **belassen** (AGENTS.md-Entscheidung „aus Kontinuität MacRadio"). Nur Repo/Ordner
  heißen `mucke_baby`. Falls doch voller Umbau gewünscht → Migrationsschritt einplanen.

## UI / Kopfzeile (offen)

- [ ] **U1 — Titel + Version inline OHNE Toolbar-Kapsel.** Wunsch: „Mucke, Baby!" groß,
  „v1.5.0" klein/grau **daneben auf einer Linie**, KEINE macOS-26-Glas-Kapsel. Custom
  `ToolbarItem`/`.principal` erzwingt aktuell die Kapsel. Aktuell stattdessen: nativer
  `navigationTitle` + `navigationSubtitle` (Version darunter, kapsellos). **Prüfen, ob's
  doch geht:** z.B. `navigationTitle(Text(attributed))` mit gemischter Schrift, eigener
  Titlebar-Accessory-View (`NSTitlebarAccessoryViewController`), oder Toolbar-Kapsel per
  Style unterdrücken. macOS 26 (Tahoe). Wenn unmöglich: so lassen.

## Bugs / dringend (aus Screenshot 2026-06-07)

- [x] **B1 — Verlauf-Platzhalter pro Sender-Session.** `SongHistory.beginSession()` legt
  bei aktivierter Aufnahme einen Platzhalter („Mitschnitt") ab Startzeit an; `start`
  deckt sich mit dem Recorder-Clip-Start (Export-Offset 0). Kommt der erste echte Titel
  < 5 s später, wird der Platzhalter verworfen (kein 0-Sek-Eintrag bei Titel-Sendern),
  sonst bleibt er (titel-lose Lücke). End-to-End geprüft: Hirschmilch (opus, titellos) →
  Platzhalter bleibt, Mitschnitt **erreichbar**; A.D.M. (mit Titel) → kein Platzhalter.
- [x] **B2 — Footer: Laufzeit des Senders.** `RadioPlayer.playStartedAt` (ab erstem Audio);
  Laufzeit mm:ss / h:mm:ss via `TimelineView(.periodic 1 s)` in der Footer-Transport-Leiste.

## Erledigt in dieser Session (2026-06-07, v1.5.0)

- Verlauf-Pruning: < 5 s sofort beim Schließen (`closeCurrent`), < 20 s bei Start (`load`)
  und Beenden (`willTerminate`) — inkl. Altbestand. (`SongHistory`)
- Echte Schriftskalierung CMD +/−/0: `dynamicTypeSize` wirkt auf macOS NICHT → eigener
  `uiFontScale`-Environment + `scaledFont` (explizite `.system(size:)`). Funktioniert.
- Kopf/Footer-Umbau: Titel nativ + `v1.5.0`-Untertitel; Play/Stopp + Laufzeit + Lautstärke
  als saubere Transport-Leiste im Footer (Toolbar-Custom-Content = macOS-26-Kapseln, s. U1).
- Verlauf-Klick-Fix: `.onDrag` → `.draggable` (verträgt sich mit Selektion), Export off-main;
  `Recorder` `@unchecked Sendable`, `SongEntry` `Sendable`.
- Songtext: mehrere Query-Varianten + **„Im Web suchen"**-Fallback (lyrics.ovh deckt
  Hardstyle/Techno kaum ab). (`LyricsView`, `SongLink`)
- Icon brushed s123 finalisiert (s. I1).
- Versionsquelle: `AppInfo.version` (war tote Konstante) → `build.sh` stempelt sie in die
  Info.plist; im Kopf angezeigt. 1.4.1 → 1.5.0.
- Default-Senderliste: `macradio-sender.json` (50 Sender) → `Resources/seed-stations.example.json`
  (öffentlich, für jedermann bei Neuinstallation).

## Theme-System (erledigt 2026-06-07, v1.6.0)

- [x] **7 Themes** umschaltbar: `schlicht` (= bisheriges natives Aussehen, dark/light) +
  6 Design-Entwürfe (`acid`/`retro`/`fanzine`/`marshall`/`danish`/`midi`) aus `design-proposal/`.
  Umschalt-Button im Kopf. Eine theme-parametrisierte Codebasis, kein Fork. Spec:
  `design-proposal/THEME-PLAN.md`. Alle 7 visuell verifiziert (`design-proposal/shots/`).
- [x] **Console-Layout** (3 Spalten Stations|Stage|History + Transport) für die Design-Themes;
  `schlicht` behält das classic-Layout. `StageView` + `VisualizerView` + `ConsoleTransportBar`.
- [x] **Prozedurale Material-Texturen** (Canvas) statt Bitmaps — lokal, scharf, kontrastsicher.
- [x] **T1 — Bildgenerierungs-ssh** wieder verfügbar; Lehren (ControlMaster, sequenziell, inline-Opts) im Projekt-Wissensindex.
- [x] **T2 — img2img-Theme-Texturen** erzeugt (mflux/Z-Image), gebündelt unter
  `Resources/themes/`, via `ThemedSurface` + Kontrast-Scrim gezeigt; prozedural = Fallback.
  Log: `design-proposal/.asset-log.md`.
- [ ] **T3 — Feinschliff Designtreue** (optional): echte geriffelte Knöpfe (marshall),
  handschriftliche Verlauf-Font (retro), Stempel-Buttons (fanzine), Mehrkanal-Meter rechts (midi).
- [x] **T4 — Stage-Mitte überarbeiten** — durch den Layout-Umbau erledigt: Stage-Mitte zeigt
  nur noch den Visualizer (kein redundanter Titel mehr), Now-Playing sitzt groß+kopierbar im
  Fuß. `StageView` = `ThemedSurface` + `VisualizerView` (retro: Mess-Panel).
- [ ] **T5 — Visualizer AUDIO-REAKTIV** (wichtig — sonst witzlos). Die Theme-Visualizer
  (`VisualizerView`) animieren aktuell nur per `TimelineView` (Zeit), **nicht** zur Musik →
  bewegt sich nicht zum Sound. Muss echten Pegel/Spektrum bekommen. VLCKit liefert **kein
  PCM** → **CoreAudio Process-Tap** (macOS 14.4+) auf die eigene App-Ausgabe → FFT
  (Accelerate/vDSP) → Level/Bänder als Eingang für `VisualizerView` (Waveform/VU/Bars/Notes
  reagieren). **Verbindet sich mit V3** (Metal-Visualizer, gleicher Tap kann beide speisen) —
  Tap einmal bauen, beide nutzen.

## Visualizer (entschieden: nativ Metal, audio-reaktiv, Start RetroOutrun)

> Hinweis: Die **Theme-Visualizer** (`VisualizerView`, TimelineView-animiert) sind **dekorativ**
> und unabhängig vom hier geplanten **audio-reaktiven Metal-Visualizer** (V1–V4). Letzterer
> bleibt offen; ein CoreAudio-Tap (V3) könnte später beide speisen.

- [ ] **V1 — Metal-Renderer.** Fullscreen-Quad in `MTKView` via `NSViewRepresentable`,
  Fragment-Shader (MSL). Uniforms: `iTime`, `iResolution` (+ Audio, s.u.).
- [ ] **V2 — RetroOutrun-Shader portieren.** Quelle: `~/git/p_fraktal/frontend/src/panels/
  ShadertoyPanel.tsx` (Titel „RETRO OUTRUN // HORIZON SCAN", Attribution „Outrun
  Landscape by Antigravity"); Registry-Name evtl. `ShaderRetroWave`. GLSL/Shadertoy
  (`mainImage`) → MSL (mechanisch). Lizenz/Attribution mitnehmen.
- [ ] **V3 — Audio-Reaktivität.** CoreAudio Process-Tap (macOS 14.4+) auf die eigene
  App-Ausgabe → FFT (Accelerate/vDSP) → Level/Bänder als Shader-Uniform (Terrain am
  unteren Rand reagiert). VLCKit gibt kein PCM raus → Tap ist der saubere Weg.
- [ ] **V4 — Einbinden + Perf.** Als dimmer Hintergrund (Schalter, Default aus). Nur
  rendern wenn sichtbar, FPS-Cap, interne Auflösung runter bei schweren Shadern.
  **Darf die App nicht aufblähen** (Shader = Text + kleiner Metal-Host).
- Später: VoxelNeon / MandelBox als weitere Hintergründe (gleicher Host).

## Recorder-Export (Code da, Laufzeit-Test offen)

- [ ] **R1 — Export runtime-testen.** Song aus echter Aufnahme schneiden (harter Schnitt
  + ein-/ausgefadet) → m4a prüfen (`afinfo`, Segment korrekt). Drag&Drop aus der Liste
  testen. Code: `SongExporter.swift`, `HistoryPanel.swift`.
- [ ] **R2 — ogg/opus-Schnitt.** AVFoundation kann ogg/opus nicht → aktuell Hinweis.
  Optional: ffmpeg nutzen falls vorhanden (Hirschmilch/RainWave betroffen).

## Icons

- [x] **I1 — Finale Icon-Variante gewählt: `brushed s123`** (Stahl-Cone, schwarzes Squircle).
  `Resources/AppIcon.icns` ersetzt (Master `icons/MacRadio-brushed-s123.icns`), Social-Banner
  neu `icons/social-brushed-s123.png`. Reproduzierbar: `icons/make-icns.sh`, `icons/make-banner.swift`.
- [ ] **I2 — GitHub Social-Preview hochladen.** `icons/social-brushed-s123.png` in den
  Repo-Settings setzen (geht nicht per Git).

## Release / Doku

- [x] **GitHub-Release-Infrastruktur (2026-06-09, v1.7.31):** `CHANGELOG.md` angelegt (Keep a
  Changelog, Englisch). `wrappers/sign-and-release.sh --publish` baut, setzt git-Tag, lädt DMG
  hoch, zieht Release-Notes aus CHANGELOG. Ohne `--publish` unverändert lokales DMG.
  **Nächster Schritt (Daniel):** `gh auth status` prüfen, dann `bash wrappers/sign-and-release.sh --publish`.
- [ ] **D1 — README.de.md** (deutsche Fassung) + Sprachumschalt-Zeile, falls GitHub-Release
  (globale Regel mehrsprachige README).
- [ ] **D2 — Aufnahme-Default für Public.** Für eine Veröffentlichung Default auf AUS
  erwägen (aktuell AN, README warnt).
- [ ] **D3 — Alternativen recherchieren** (eigenes Todo im zentralen Wissensindex): welche Mac-Apps können
  Stream-Aufnahme + Song-Export, zu welchen Konditionen? (Daniel fand früher nichts
  Kostenloses ohne Gängelung.)

## Visuell prüfen (durch Daniel)

- [ ] Dark/Light-Mode beide ok. CMD +/−/0 skaliert sauber, Footer-Scroll bei großer Schrift.
  Verlauf-Aktionen (Apple Music/Spotify/Songtext/Export) + Drag&Drop.

## Erledigt (Referenz)

VLCKit (alle Codecs), Now-Playing (eigener ICY-Reader), Verlauf-Panel + Aktionen
(Apple Music exakt via iTunes-API, Spotify/Web, Songtext via lyrics.ovh), Genre-Listen,
JSON Im-/Export, Footer (Interpret fett/Titel normal, scrollbar), Dark/Light, Rename
„Mucke, Baby!", App-Icon + Social-Banner, Recorder-Core (Dauer-Dump, 10-GB-Schutz,
24h-Rollover), Verlauf-Löschen-nach-Alter, CMD +/−, Sender-Healthcheck, Song-Export (Code).
