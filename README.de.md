# Mucke, Baby!

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

![Mucke, Baby!](icons/social-s123.png)

Ein nativer macOS-Internetradio-Player (SwiftUI + VLCKit) mit sieben handgemachten Themes und audio-reaktiven Visualizern, die synchron zum tatsächlichen Klang laufen. Ursprünglich vom Linux-Mint-Applet **Radio++** inspiriert — inzwischen ein eigenständiges Projekt, mit Verlauf, Stream-Aufnahme (inkl. songweiser Extraktion), Direktlinks zu Apple Music / Spotify und mehr. Es gibt auch einen iPhone-Ableger: [Baby, Mucke!](https://github.com/DanielMuellerIR/baby_mucke).

## Download

**[➜ Aktuelles signiertes & notarisiertes DMG herunterladen](https://github.com/DanielMuellerIR/mucke_baby/releases/latest)** — öffnen, „Mucke, Baby!“ in den Programme-Ordner ziehen und doppelklicken. Mit Developer ID signiert und von Apple notarisiert, öffnet also ohne Gatekeeper-Warnung. Benötigt macOS 14.2 oder neuer (Apple Silicon).

Lieber selbst aus dem Quellcode bauen? Siehe [Starten](#starten-kommandozeile--headless-tauglich) weiter unten.

## Screenshots

<p align="center"><img src="assets/screenshots/acid.png" width="860" alt="Acid Rave — Neon-Oszilloskop"></p>

| Standard | Retro | Fanzine |
|:--:|:--:|:--:|
| ![Standard](assets/screenshots/standard.png) | ![Retro](assets/screenshots/retro.png) | ![Fanzine](assets/screenshots/fanzine.png) |
| **GuitarAmp** | **Danish** | **Black MIDI** |
| ![GuitarAmp](assets/screenshots/guitaramp.png) | ![Danish](assets/screenshots/danish.png) | ![Black MIDI](assets/screenshots/midi.png) |

## Starten (Kommandozeile / headless-tauglich)

Kein Xcode-Projekt — die App wird mit `swiftc` zu einem `.app`-Bundle kompiliert. Es genügen die Command Line Tools. Die gesamte Toolchain ist skriptbar (praktisch für Automatisierung und KI-Agenten):

```bash
./build.sh                                       # baut "build/Mucke, Baby!.app" (lädt VLCKit einmalig, ~84 MB)
./run.sh                                         # bauen + starten
open "build/Mucke, Baby!.app"                    # starten
"build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby" # starten mit Logs (Debug)
```

### Headless / Automatisierung

- **Theme-Screenshots ohne UI-Sitzung:** `MUCKE_SHOTS=<verzeichnis>` setzen — die App schaltet durch alle Themes, schreibt je ein PNG und beendet sich. `MUCKE_SHOT_W=<px>` überschreibt die Fensterbreite.
  ```bash
  MUCKE_SHOTS=/tmp/shots "build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby"
  ```
- **Signiertes + notarisiertes DMG** (Developer ID, Hardened Runtime, DMG mit Hintergrundbild):
  ```bash
  bash wrappers/sign-and-release.sh                # → build/Mucke-Baby-<version>.dmg, Gatekeeper-sauber
  ```

## Funktionen

- Spielt **alle Codecs** über VLCKit/libVLC (mp3, aac, **ogg, opus**, flac, …).
- **Sieben Themes**, je mit eigenem Layout, eigenen Texturen und eigenem Visualizer: Standard, Acid Rave, Retro, Fanzine, GuitarAmp, Danish, Black MIDI.
- **Audio-reaktive Visualizer** — analoge VU-Nadeln, Oszilloskop, Spektrum-Balken und eine Piano-Roll — gespeist von einem **CoreAudio-Process-Tap** auf die eigene Tonausgabe. Das getappte Signal wird vor der Analyse normalisiert, damit leiseres Hören den Visualizer nicht kleiner macht; das Bild bleibt perfekt synchron und flüssig (~90 Hz).
- **Now-Playing** (Interpret/Titel) über einen eingebauten ICY-Metadaten-Leser (markier- und kopierbar), mit korrekter Dekodierung von Nicht-UTF-8-Sendern (UTF-8 → Shift-JIS/CP932 → Latin-1, z. B. japanische Sender).
- **Verlauf** — jeder Titel mit Start-/Endzeit und Sender, auch über Senderwechsel hinweg.
- **Optionale Stream-Aufnahme** (standardmäßig aus) — schneidet den laufenden Stream nach `~/Music/MuckeBaby/Aufnahmen/` mit, inkl. songweiser Extraktion; stoppt automatisch bei unter 10 GB frei.
- **Direktlinks** aus dem Verlauf, um einen Titel in Apple Music oder Spotify nachzuschlagen.
- Senderliste mit Play/Stop, Ein-/Ausblenden und Umsortieren pro Sender; ein **Favorit**, der beim Start automatisch spielt.
- Sender hinzufügen / bearbeiten / löschen; **kuratierte Genre-Listen** per Klick importieren.
- Playlist-Auflösung für `.pls` / `.m3u` / `.asx` / `.xspf` / radiotime `Tune.ashx`.
- Sendersuche über die offene API von [radio-browser.info](https://www.radio-browser.info).
- Hell- & Dunkelmodus; optionales Menüleisten-Symbol (standardmäßig aus).

### Berechtigung für die Audio-Reaktivität

Die Visualizer lesen die eigene Tonausgabe über einen CoreAudio-Process-Tap. Beim ersten Start fragt macOS **einmalig** nach der Erlaubnis zur Audioaufnahme; sie ist für die reaktiven Visuals nötig (mit Developer-ID-Signatur wird die Erlaubnis dauerhaft gemerkt). Die App-Lautstärke wird vor der Analyse herausgerechnet; bei komplett stummer Wiedergabe gibt es kein Signal zum Rekonstruieren. Ohne Erlaubnis spielt die App trotzdem — die Visualizer ruhen dann nur.

## Daten

Die Sender liegen in einer editierbaren JSON-Datei:

```
~/Library/Application Support/MuckeBaby/stations.json
```

Beim ersten Start wird sie aus `Resources/seed-stations.json` befüllt, falls vorhanden, sonst aus der generischen `Resources/seed-stations.example.json` (die einzige mitgelieferte Liste).

## Fremdbestandteile & Lizenzen

Vollständige Aufstellung in [`THIRD-PARTY.md`](THIRD-PARTY.md). Kurz:

- **VLCKit / libVLC** — **LGPL-2.1-or-later**, dynamisch gelinkt und im Bundle austauschbar. Quelle: <https://code.videolan.org/videolan/VLCKit>.
- **Theme-Texturen & App-Icon** — lokal mit einem Apache-2.0-Modell erzeugt (kommerzielle Nutzung erlaubt).
- **Schriften** — macOS-Systemschriften (nicht mitgeliefert). **Sender-URLs** sind Fakten; die Streams gehören den jeweiligen Sendern.

**Projekt-Lizenz:** [MIT](LICENSE) für den eigenen Quellcode dieses Projekts. Das eingebettete VLCKit/libVLC behält seine **LGPL-2.1-or-later**-Lizenz (dynamisch gelinkt und austauschbar; Pflichten erfüllt durch diesen Hinweis + den Quell-Link oben).

## Voraussetzungen

macOS **14.2+**, Apple Silicon, Xcode Command Line Tools (`xcode-select --install`).

---

*Status: privates Projekt. Ursprünglich vom Linux-Mint-Applet „Radio++" angestoßen und inzwischen weit darüber hinausgewachsen — es wurde kein Code und kein Asset von Radio++ übernommen.*
