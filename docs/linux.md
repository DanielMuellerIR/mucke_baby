# Mucke, Baby! unter Linux

Die Linux-Anwendung verwendet C++17 und Qt Widgets ab Version 6.4. Audio spielt
weiterhin libVLC 3; unter Linux wird die vom Betriebssystem gelieferte Bibliothek
dynamisch geladen. Für die Oberfläche läuft kein Browser und kein Python-Prozess.
Python wird nur für Installation und Prüfskripte benötigt.

## Bauen und installieren

Abhängigkeiten unter Linux Mint 22 / Ubuntu 24.04:

```bash
sudo apt install build-essential cmake pkg-config qt6-base-dev qt6-wayland \
  qt6-translations-l10n libvlc-dev vlc-plugin-base libpulse-dev \
  nlohmann-json3-dev ffmpeg ca-certificates python3
```

Unter CachyOS / Arch Linux:

```bash
sudo pacman -S --needed base-devel cmake pkgconf qt6-base qt6-wayland \
  qt6-translations vlc vlc-plugins-base vlc-plugin-ffmpeg libpulse \
  nlohmann-json ffmpeg ca-certificates python
```

Im Projektverzeichnis:

```bash
./build.sh                  # Linux-Build nach build/linux/
./install.sh                # Benutzerinstallation nach ~/.local, ohne sudo
~/.local/bin/mucke-baby
# Alternativ direkt aus dem Projekt: ./run.sh
```

Die vorhandenen Einstiegsskripte wählen die Plattform. Der macOS-Bau bleibt beim
bestehenden Swift-/Notarisierungsablauf. `MUCKE_BUILD_JOBS=2` begrenzt die
parallelen Buildjobs; `MUCKE_BUILD_DIR` und `MUCKE_INSTALL_PREFIX` überschreiben
Buildverzeichnis und Installationspräfix. `./install-linux.sh --no-build`
installiert einen bereits vorhandenen Build.

Der Linux-Installer startet die Oberfläche nicht. Er prüft das kopierte Programm
mit `--version`, legt einen Versionsordner unter `~/.local/lib/mucke-baby/` an und
schaltet Starter, Menüeintrag und Symbol um. Bei einem Fehler nimmt er diese
Änderungen zurück. Vorhandene Versionsordner bleiben erhalten. Der Menüeintrag
heißt **Mucke, Baby!**; es wird kein Autostart des Desktops eingerichtet.

`./release.sh` erzeugt unter Linux ausschließlich ein lokales TAR.GZ-Archiv.
Das Archiv enthält das Programm, Starter, Symbol und Lizenzhinweise; Qt, libVLC,
PulseAudio und FFmpeg kommen aus den Systempaketen. Es ist kein AppImage und
installiert keinen Hintergrunddienst. Ein öffentliches Release wird dadurch
nicht angelegt.

## Daten und Aufnahme

- Bibliothek: `$XDG_DATA_HOME/MuckeBaby/library.json`, normalerweise
  `~/.local/share/MuckeBaby/library.json`. Sender, Gruppen und Merkliste werden
  gemeinsam atomar gespeichert.
- Verlauf und Einstellungen liegen getrennt im selben Datenverzeichnis.
- Cache: `$XDG_CACHE_HOME/MuckeBaby/`, normalerweise `~/.cache/MuckeBaby/`.
- Aufnahmen: Musikordner aus der Desktopkonfiguration,
  Unterordner `MuckeBaby/Aufnahmen/`.

Die Aufnahme ist zunächst aus. **Verlauf löschen** im Menü **…** des Verlaufs
erhält Aufnahmen und Merkliste.
Aufnahmen werden gesondert und nach Bestätigung gelöscht; eine laufende Aufnahme
bleibt geschützt. Bei weniger als 10 GiB freiem Platz stoppt die Aufnahme.

Die Linux-Bibliothek hat ein eigenes lokales Format. Für den Austausch mit Mac
und iPhone dient das portable Bibliotheksformat V1/V2/V3 über Importvorschau und
Konfliktwahl. Importierte Erkennungsherkunft bleibt einschließlich großer
Ganzzahlrevisionen erhalten. Die persönliche lokale Seed-Datei wird im Linux-Bau
nicht eingebunden; neue Bibliotheken verwenden ausschließlich die öffentliche
Beispielliste.

## Songexport und temporärer Puffer

Im Verlauf lassen sich mit Strg beziehungsweise Umschalt bis zu 100 Titel
markieren und über **Audio exportieren** vorbereiten. Die Analyse liest die
aufgezeichneten Bytegrenzen und ordnet sie Audio-Paketen zu. Sie schätzt Schnitte
nicht anhand der Empfangsuhr. Unvollständige Titel und ungenaue Ogg-Seitengrenzen
brauchen eine ausdrückliche Zustimmung; bei Ogg kann benachbartes Audio enthalten
sein. Fehlende oder laufende Aufnahmen werden mit ihrem Status angezeigt.

Anfang, Ende und Fades sind korrigierbar. Vorschau und Speichern verwenden exakt
dieselbe vorbereitete M4A-Datei. Ein Stapel verarbeitet die Titel nacheinander;
vorhandene Dateien bleiben erhalten und erhalten bei Namenskollisionen einen
nummerierten Zusatz. Aufnahmedateien und Verlauf bleiben unverändert.

Der temporäre Puffer ist zunächst aus. Nach Bestätigung hält er höchstens fünf
Minuten und 32 MiB komprimiertes Audio zuzüglich eines begrenzten Index. Er nutzt
die vorhandene ICY-Verbindung. Pause, Zeitsprünge und Live funktionieren nur für
nachgewiesene Decoderprofile; ein pausierter, inzwischen abgelaufener Abschnitt
wird gestoppt. Abschalten, Senderwechsel und Beenden entfernen temporäre Daten.
Dauerhafte Aufnahmen bleiben erhalten.
Zusätzlich ist der interne VLC-Vorauslesepuffer in diesem MP3-/AAC-Zeitversatzpfad
auf 2 MiB mit 64-KiB-Leseblöcken begrenzt. Direkte URL-Wiedergabe nutzt die
VLC-Standardeinstellungen.

Die vermessenen Profile betreffen libVLC 3.0.20 und 3.0.24: MP3 mit 16, 22,05,
24, 32, 44,1 und 48 kHz sowie AAC-ADTS mit 32, 44,1 und 48 kHz. AAC mit
abweichender tatsächlicher Decoderrate, MP3 mit Xing/Info/VBRI-Dateikopf und
andere VLC-Versionen spielen direkt weiter. Ogg/Vorbis, Opus, FLAC und HLS
spielen ebenfalls direkt; für HLS gibt es weder Aufnahme noch Puffer.

## Desktop und Audio

Medientasten und Desktopsteuerung verwenden MPRIS über den vorhandenen
D-Bus-Benutzersitzungsbus. Ein optionales Tray-Symbol kann die App beim Schließen
weiterlaufen lassen. Der private Steuerkanal ist ein benutzergeschützter lokaler
Socket; es wird kein Netzwerkport für die Bedienung geöffnet.

Die Visualizer lesen ausschließlich den eindeutig zugeordneten Audioausgang
dieses Prozesses über PulseAudio beziehungsweise PipeWire-Pulse. Andere Anwendungen
werden nicht aufgenommen. Fehlt ein eindeutiger Ausgang, ruht die Darstellung;
die Radiowiedergabe benötigt den Monitor nicht. Die Analyse arbeitet mit einem
kleinen PCM-Puffer und pausiert bei unsichtbaren Visualizern. Echte Stille und
0 Prozent Lautstärke bleiben still.

Apple-spezifische Dienste bleiben Plattformgrenzen: ShazamKit-Erkennung und
Apple-Kurzbefehle sind unter Linux nicht verfügbar. Die Linux-App verwendet keinen
Sparkle-Updater; Updates erfolgen durch erneutes Bauen und Installieren. Die
portablen Datenformate behalten importierte Erkennungsdaten trotzdem bei.

## Prüfen und automatisieren

```bash
ctest --test-dir build/linux --output-on-failure
MUCKE_MEDIA_RUNTIME_TEST=1 sh linux/tests/media_run_tests.sh
sh linux/tests/ui_song_backend_test.sh build/linux/ui_song_backend_test
# Optionaler längerer AAC-Lauf; Standard: 18 Minuten, zulässig: 340–1200 Sekunden:
MUCKE_MEDIA_RUNTIME_TEST=1 MUCKE_MEDIA_TEST_MODE=soak-aac \
  MUCKE_MEDIA_SOAK_AAC_SECONDS=1080 sh linux/tests/media_run_tests.sh
# Privater Pulse-Server und isolierter D-Bus; benötigt dbus-run-session.
dbus-run-session python3 linux/tests/app_runtime_test.py build/linux/mucke-baby
```

Die Laufzeitprüfung erzeugt eigene lokale Tonstreams und einen privaten
Audio-Server mit Null-Ausgang. Sie verändert weder Senderbestände noch den
Audioausgang des Desktops. Zusätzliche Testwerkzeuge sind unter anderem
`pulseaudio`, `pulseaudio-utils`, `dbus-x11` und `ffmpeg`.

Die laufende App lässt sich aus derselben Benutzersitzung steuern:

```bash
mucke-baby --status
mucke-baby --play '<gespeicherte Sender-ID>'
mucke-baby --volume 50
mucke-baby --stop
```

`--data-dir`, `--cache-dir` und `--recordings-dir` ermöglichen isolierte Prüfstände.
`--no-autoplay` unterdrückt die gespeicherte Startwahl. `--no-window` lässt die
Oberfläche geschlossen. Diagnoseoptionen und Screenshotaufruf stehen unter
`mucke-baby --help`.
