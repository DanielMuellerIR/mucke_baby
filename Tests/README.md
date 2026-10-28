# Kernprüfungen

## Linux

`bash build-linux.sh` baut die Qt-/libVLC-Anwendung und ihre Prüfprogramme.
`ctest --test-dir build/linux --output-on-failure` prüft Daten, Ressourcen,
Installation, MPRIS sowie die deutsche und englische Oberfläche ohne sichtbares
Fenster. Die Oberflächenprüfung erfasst alle sieben Themes bei normaler und
schmaler Breite, Mini-Player, Tastaturbedienung und Visualizer mit Signal/Stille.

`MUCKE_MEDIA_RUNTIME_TEST=1 sh linux/tests/media_run_tests.sh` prüft zusätzlich
Wiedergabe, Aufnahme, Audiopuffer, Export, Timer und Audioeffekte gegen lokale
Tonfixtures mit einem eigenen PulseAudio-Server und Null-Ausgang.
`dbus-run-session -- python3 linux/tests/app_runtime_test.py build/linux/mucke-baby`
prüft die echte Anwendung einschließlich MPRIS und lokaler Prozesskommunikation;
`MUCKE_RUNTIME_GUI=1` bezieht das Hauptfenster über den Qt-Offscreen-Treiber ein.
Diese Läufe benötigen die in [docs/linux.md](../docs/linux.md) genannten Werkzeuge
und verwenden eigene temporäre Daten. Sie ersetzen keinen Hörtest oder die
visuelle Abnahme auf dem Ziel-Desktop.

## macOS

Der `RecordingLibraryHarness` prüft Audioverfügbarkeit und Zeitgrenzen, aktive/fehlende/manipulierte Dateien, getrennte Verlaufsdaten, Schreib-/Löschfehler und die Wiederherstellung unterbrochener Entfernungen. `recording-preview.py` prüft den lokalen VLC-Vorschaupfad einschließlich alter Ereignisse, Dateiende und Stop.

`bash Tests/run-tests.sh` kompiliert und startet die vorhandenen Swift-Harnesses,
prüft Fleet-Regeln und Wiedergabeereignisse. Es startet keine App und nutzt keine
Nutzerdaten. Der Export-Harness erzeugt seine eigene PCM-Tonfixture; AVFoundation
muss auf die macOS-Mediendienste zugreifen können. Eine Sandbox kann diese Dienste
oder den lokalen HTTP-Fixtureserver blockieren.

Der `LibraryExchangeHarness` prüft V1/V2/V3-Importe mit den echten Stores,
unterbrochene Transaktionen in beiden Neustartreihenfolgen und Senderimporte bei
bereits vorhandenen Erkennungsmerkungen. `FixtureToneHarness` und
`python3 Tests/timeshift-recognition-checks.py` prüfen die Tonzuordnung und den
unabhängigen Bandenergieanteil mit 440/880 Hz sowie Fremdtönen, Oktavfehlern und
Stille. Die separate Python-Prüfung benötigt `ffmpeg` im PATH.

Der AudioTap-Harness speist synthetische Samples direkt in die unveränderte
Analyse ein; er öffnet kein CoreAudio-Gerät. `release-mount.py` führt den
Mount-Abschnitt des Release-Skripts mit einem gemockten `hdiutil` nur in einem
Temp-Verzeichnis aus. Er prüft Erfolg und Abbruch, ohne Volumes einzuhängen,
zu signieren, zu notarisieren oder etwas zu installieren.

`release-publish.py` prüft die Zielauswahl und den Tag-Push mit temporären lokalen
Git-Repositories. Mehrere Ziele werden abgewiesen; automatische zusätzliche Tags
und ein gleichnamiger Branch dürfen nicht veröffentlicht werden.

`python3 Tests/export-codecs.py` benötigt `ffmpeg` und `ffprobe` im PATH. Der Lauf
erzeugt zwölf Sekunden lange synthetische MP3-/AAC-/Ogg-/Opus-Töne in einem eigenen
Temp-Verzeichnis. Der produktive Recorder schreibt die Bytes, SongExporter
schneidet hart und gefadet, ffmpeg decodiert alle acht Ausgabedateien unabhängig.
Der ausgegebene Belegordner enthält Quellen, Exporte und SHA-256-/Codec-Ergebnisse.
Er darf nach der Auswertung entfernt werden.

Codecunterstützung des Exports hängt von macOS ab. Die vier Formate wurden auf
macOS 26.6.2 geprüft; damit ist ihre Unterstützung auf macOS 14.2 nicht belegt.
Unlesbare Aufnahmen müssen kontrolliert abgewiesen werden. Wiedergabe über VLCKit
und echte GUI-/Drag-Prüfungen sind gesonderte App-Abnahmen mit notarisiertem Bundle.

Der `StationRepairHarness` prüft optionale Katalogherkunft und Altdaten, UUID-Abfragen samt Mirror-/Abbruchfällen, Vorschau ohne Speicherung, veraltete Antworten, unsichere URLs, Schreibfehler und den Erhalt lokaler Senderdaten. Kontrollierte Erreichbarkeitsproben belegen, dass Ergebnisse für eine ersetzte URL nicht mehr veröffentlicht werden.

Der `MiniWindowHarness` prüft gespeicherte Fenstergeometrie mit negativen und vertikal angeordneten Bildschirmflächen sowie entfernten Displays. Der Startup-Harness prüft, dass weitere Fenster keinen zweiten Autostart auslösen. Native Fenster-, Fokus- und Mehrdisplay-Prüfungen bleiben gesonderte Laufzeitprüfungen.

`python3 Tests/audio-effects.py` benötigt den gepinnten Vendor-Cache und FFmpeg. Das Gate misst echten VLCKit-PCM-Ausgang mit neutralem Equalizer, Bandabsenkung und Headroom; es prüft keinen CoreAudio-Lautstärkeregler oder Hörtest. AudioSettingsHarness und PlayerHarness prüfen zusätzlich Dateischutz, atomare Speicherung, lokale Senderidentität, Playerwechsel, Retry und Stumm.

## Experimenteller Zeitversatz

`TimeshiftHarness` prüft Frame-/Bytezeit, fragmentierte Pakete, Grenzen, Titel, aktive Ausschnitte, Disk-Gate und den Erhalt dauerhafter Dateien. Die isolierte native MP3-Probe und die frühe Codecprüfung sind in [docs/timeshift-experiment.md](../docs/timeshift-experiment.md) beschrieben. Der normale Player aktiviert sie nicht.

## Zeitversatz im Player

`Tests/timeshift-player.py` prüft die Produktklasse mit steuerbaren VLC-Ereignissen
und echtem MP3-Puffer: Startreserve, gehörte statt empfangene Titel, Seek in Pause,
Live, alte Ausgangsereignisse und Überlauf. `Tests/timeshift-transport.py` baut
einen isolierten nativen Prüfhost mit echten Produktansichten; der Lauf gehört
in die Ressourcen-FIFO. Details und Grenzen: [Audiopuffer](../docs/timeshift-buffer.md).

`python3 Tests/timeshift-seek.py prepare ROOT` bereitet das native Seek-Gate vor.
`run ROOT` gehört in den exklusiven nativen Prüfblock. `verify ROOT` vergleicht
Framepositionen in MP3 CBR/VBR/MPEG-2/MPEG-2.5 und AAC-LC/HE-AAC/HE-AAC v2 mit direkter VLC-Dateidecodierung,
einschließlich der ersten Samples. Bei VLCKit-Wechsel oder einer Änderung der
Ausgabezeitkorrektur muss dieses Gate erneut bestehen.


`python3 Tests/timeshift-integration.py prepare ROOT` baut den gemeinsamen nativen
Prüfhost und synthetische ICY-/HLS-Sender. `run ROOT` gehört in die Ressourcen-FIFO
und benötigt `MUCKE_AX_TOOL`. Der Lauf prüft Aufnahmewechsel in Pause, gehörte
Dateizuordnung, echte Timer-/Medientastenbedienung, Wiederverbindung, Disk-Gate,
vollen Pufferüberlauf, DE/EN-Ansichten, Exporte und den tatsächlichen Puffer-EQ.
`verify ROOT` prüft Exporte, Verbindungen und Frequenzwirkung unabhängig.
Schlafcallbacks ersetzen keinen echten Systemschlaf; alle Daten sind isoliert.

## Mac/iPhone-Austausch

`bash Tests/exchange-interop.sh ../baby_mucke` kompiliert beide tatsächlichen
Produktions-Codecs getrennt und prüft V1/V2/V3 in beiden Roundtrip-Richtungen. Das
iPhone-Repo muss die V3-Unterstützung enthalten. Der Test erhält eigene Namen,
Gruppen, Favoriten und getrennte Radio-Mixe, prüft direkte/gepufferte Hörkontexte
mit maximaler UInt64-Revision und weist ungültige Kontexte sowie unbekannte oder
falsch deklarierte Versionen ab. Die Konfliktvorschau muss reine
Hörkontextunterschiede sichtbar machen. Die JSON-Gegenprüfung erfolgt unabhängig
in Python. Ergebnisdatei: `build/tests/exchange-interop/result.json`.

Der Test belegt Dateikompatibilität. Reale AirDrop-/Dateien-/Teilen-Übergaben
zwischen Mac und iPhone bleiben eine eigene Geräteprüfung.
