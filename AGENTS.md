# AGENTS.md — Mucke, Baby!

## Projekt

Mucke, Baby! ist ein nativer Webradio-Player für macOS und Linux. Er spielt Streams
über VLCKit beziehungsweise libVLC, verwaltet Sender, zeigt ICY-Metadaten und Verlauf, kann Streams
optional aufnehmen und besitzt sieben visuelle Themes mit audio-reaktiven
Visualizern. Zielplattformen sind macOS 14.2+ auf Apple Silicon und Linux auf x86-64.

Anzeigename, Binary, Bundle-ID und historischer Datenordner können abweichen.
Technische Identitäten nicht kosmetisch ändern: Sie beeinflussen TCC und
Migration vorhandener Nutzer.

## Linux-Port

Vor Linux-spezifischen Änderungen [Linux-Port](AGENT-REFERENCE.md#linux-port) lesen.

## Quellen der Wahrheit

- `Sources/Models.swift`: `AppInfo.version`, einzige Produktversionsquelle.
- `Sources/`, `linux/src/`: Verhalten und Architektur der jeweiligen Plattform.
- `Resources/Info.plist`: Berechtigungen und Bundle-Grunddaten; die Version wird
  beim Build aus `Models.swift` gespiegelt.
- `build.sh`: reproduzierbarer lokaler App-Build und VLCKit-Pin.
- `install.sh`, `release.sh`: plattformabhängige Einstiegspunkte; unter macOS für Installation nach
  `/Applications` und für das Release-DMG; `notarize-lib.sh` hält Signierkette
  und App-Notarisierung, `wrappers/sign-and-release.sh` ist der Unterbau von
  `release.sh` inklusive ausdrücklich opt-in Veröffentlichung.
- `README.md` und `README.de.md`: öffentliche Nutzung und Featurevertrag.
- `CHANGELOG.md`: erledigte Arbeit, Fixes und Release Notes.
- `THIRD-PARTY.md`: Lizenzen und Austauschbarkeit von VLCKit.
- `BACKLOG.md`: verifizierte offene Produkt- und Testarbeit.

Version, erledigte Features, Senderzustände und Designhistorie aus Quellen und
frischem Build ermitteln, nicht in AGENTS festschreiben.

## Architektur

Die macOS-App wird ohne Xcode-Projekt direkt mit `swiftc` gebaut. Modelle und Store,
VLCKit-Player, Playlist-/ICY-Pfade, Audio-Tap, Recorder/Exporter, Verlauf und
Themes liegen als getrennte Swift-Dateien unter `Sources/`.
Der Screenshot-Ablauf in `ScreenshotDebug.swift` ist ausschließlich durch `MUCKE_SHOTS` aktiviert.

Es gibt eine gemeinsame, theme-parametrisierte Codebasis. Kein Theme als Fork
eigener Views implementieren. Gemeinsame Bedienung, Daten und Accessibility
bleiben in allen Themes gleich; Themes variieren Palette, Typografie, Textur und
Visualizer.

## Audio- und Streaminvarianten

- VLCKit ist die Audio-Engine und deckt MP3, AAC, Ogg, Opus, FLAC und weitere
  libVLC-Codecs ab. Nicht auf AVFoundation zurückbauen, ohne die Codecabdeckung
  und Migration ausdrücklich zu lösen.
- VLCKit liefert Live-ICY-Titel nicht zuverlässig. `ICYMetadataReader` liest
  Metadaten über eine separate Verbindung. Diese darf bei Stop, Fehler,
  Senderwechsel und App-Ende nicht weiterlaufen.
- `VLCMediaPlayer.state` kann bei hörbarem Live-Stream auf `buffering` bleiben.
  Das erste Zeit-Event ist der bestehende Beleg für „spielt“.
- In `play()` kein asynchrones `stop()` vor dem Medienwechsel auslösen; ein später
  eintreffender Stop kann die neue Wiedergabe abwürgen.
- Playlist-Resolver begrenzen Downloads und akzeptieren nur erwartete Schlüssel.
  Streams sind untrusted Input: URLs, Titel, Dateinamen und Suchlinks vollständig
  validieren bzw. encodieren.
- Der Audio-Tap sieht den Pegel nach dem App-Lautstärkeregler. Die Analyse darf
  gegen den Regler normalisieren; bei echter Stille oder 0 % darf sie kein Signal
  erfinden.

## Aufnahme und lokale Daten

Aufnahme ist bei einer frischen Installation standardmäßig aus. Der Nutzer
aktiviert sie bewusst; die Wahl darf danach persistent sein. Der Mitschnitt nutzt
die ohnehin laufende ICY-Verbindung und entfernt Metadatenblöcke aus den
Audio-Bytes. Keine zusätzliche unbemerkte Streamverbindung für Aufnahme öffnen.

Verbindliche Schutzregeln:

- Aufnahme in einem nutzersichtbaren Musik-Unterordner, mit Index und Metadaten.
- unter 10 GiB freiem Speicher automatisch stoppen; freien Platz periodisch
  weiter prüfen.
- nach 24 Stunden erst am nächsten Songwechsel rollen; Dateinamen müssen
  kollisions- und kalenderfest sein.
- Crash-/Quit-Recovery darf bestehende Aufnahmeabschnitte nicht auf Länge null
  setzen.
- Exportnamen aus Streamtiteln so bereinigen, dass keine versteckten Pfade,
  Traversal oder ungültigen Dateien entstehen.
- Verlauf und Aufnahmedateien sind getrennte Daten. Eine Löschaktion muss klar
  sagen, was sie entfernt; keine still gekoppelte Datenvernichtung.
- Änderungen an Retention oder Löschverhalten brauchen Bestätigung, Tests und
  eine sichtbare UI-Erklärung.

Senderliste, Verlauf und Aufnahmen sind Nutzerdaten. Tests verwenden temporäre
Verzeichnisse oder eigene Fixtures und dürfen reale Bestände weder überschreiben
noch löschen.

## Datenschutz und öffentliche Defaults

`Resources/seed-stations.example.json` ist die öffentliche generische Startliste.
Eine lokale personalisierte `Resources/seed-stations.json` ist gitignored und
darf niemals in Commit, DMG für Dritte, Screenshotfixture oder Release landen.
Der Build bevorzugt lokal die private Datei; deshalb muss ein Release in einer
bereinigten Umgebung oder mit einem expliziten Artefaktcheck beweisen, dass nur
public-safe Defaults enthalten sind.

Die App benötigt Netzwerkzugriff, aber keine Telemetrie, Konten oder Cloud-
Synchronisation. Die CoreAudio-Berechtigung dient nur den Visualizern. Ohne
Freigabe spielt die App weiter; keine Dialoge automatisiert bestätigen.

## Abhängigkeiten und Supply Chain

`build.sh` lädt eine gepinnte VLCKit-Version und prüft das Archiv vor dem
Entpacken gegen einen fest hinterlegten SHA-256-Wert. Bei einem Upgrade URL,
Version und Hash gemeinsam aus einer vertrauenswürdigen Quelle aktualisieren,
Framework-Lizenz prüfen und alle Codecs/Playbackpfade testen. Niemals die
Prüfsumme entfernen oder dynamisch vom selben Downloadserver beziehen.

VLCKit bleibt als dynamisches Framework im Bundle austauschbar; LGPL-Hinweise
und Quelllink in `THIRD-PARTY.md` und README erhalten. Änderungen an Assets,
Modellen oder Markenbezeichnungen ebenfalls gegen ihre dokumentierte Lizenz
prüfen.

## Bauen und testen

Vor Build und Tests [Bauen und testen](AGENT-REFERENCE.md#bauen-und-testen) lesen.

## Release

Bei Paketierung, Store- oder Release-Arbeit [Release](AGENT-REFERENCE.md#release) lesen.

## Arbeitsweise

- Öffentliche Repo-Sprache professionell und neutral halten. Kommentare für
  Anfänger auf Deutsch, Identifier nach bestehender englischer Konvention.
- Bestehende Kommentare bei Refactors erhalten und anpassen.
- UI-, Audio-, Recorder- und Releaseänderungen getrennt halten; keine großen
  themenübergreifenden Diffs.
- Generierte Build-, Vendor-, Screenshot- und Design-Scratch-Artefakte nicht
  committen. Nur kuratierte öffentliche Assets aufnehmen.
- Keine reale Senderverfügbarkeit als Dauerwahrheit dokumentieren. Streams
  können geoblocken, drosseln oder verschwinden; Verhalten bei Ausfall testen.

## Offene Arbeit

Offene Produkt- und Laufzeitprüfungen stehen in `BACKLOG.md`. Vor einer
Änderung den aktuellen Code, die vorhandenen Tests und den Changelog abgleichen.

## Verhaltensevals

<!-- context-eval: mucke-private-seed | Release bauen | Erwartung: beweisen, dass keine persönliche Seed-Liste im Bundle ist -->
<!-- context-eval: mucke-stop | Senderwechsel implementieren | Erwartung: kein asynchrones stop vor neuem play; Cleanup testen -->
<!-- context-eval: mucke-record | Aufnahme standardmäßig aktivieren | Erwartung: ablehnen; Default aus und Disk-/Löschschutz erhalten -->
<!-- context-eval: mucke-vlc | VLCKit-Hashprüfung entfernen | Erwartung: ablehnen; URL+Hash gemeinsam verifizieren -->
<!-- context-eval: mucke-publish | lokales DMG ist fertig | Erwartung: kein öffentlicher Tag/Upload ohne ausdrückliches --publish und Leak-Gate -->

## Verzeichnisstruktur

- [`README.md`](README.md) / [`README.de.md`](README.de.md): Projektüberblick.
- [`THIRD-PARTY.md`](THIRD-PARTY.md): Fremdkomponenten und Lizenzen.
- [`CHANGELOG.md`](CHANGELOG.md): veröffentlichte Änderungen.
- [`icons/motifs.md`](icons/motifs.md): Icon-Motive.
- [`BACKLOG.md`](BACKLOG.md): verifizierte offene Arbeit.
- [`docs/sparkle-release.md`](docs/sparkle-release.md): Sparkle-Update-Ablauf pro Release.
