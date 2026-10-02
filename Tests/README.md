# Kernprüfungen

`bash Tests/run-tests.sh` kompiliert und startet die vorhandenen Swift-Harnesses,
prüft Fleet-Regeln und Wiedergabeereignisse. Es startet keine App und nutzt keine
Nutzerdaten. Der Export-Harness erzeugt seine eigene PCM-Tonfixture; AVFoundation
muss auf die macOS-Mediendienste zugreifen können. Eine Sandbox kann diese Dienste
oder den lokalen HTTP-Fixtureserver blockieren.

Der AudioTap-Harness speist synthetische Samples direkt in die unveränderte
Analyse ein; er öffnet kein CoreAudio-Gerät. `release-mount.py` führt den
Mount-Abschnitt des Release-Skripts mit einem gemockten `hdiutil` nur in einem
Temp-Verzeichnis aus. Er prüft Erfolg und Abbruch, ohne Volumes einzuhängen,
zu signieren, zu notarisieren oder etwas zu installieren.

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
