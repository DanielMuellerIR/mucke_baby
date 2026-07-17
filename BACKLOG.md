# Mucke, Baby! — offene Arbeit

1. Recorder-Export mit echten MP3/AAC- sowie Ogg/Opus-Fällen zur Laufzeit prüfen;
   Abbruch, Sanitizing und temporäre Dateien einschließen.
2. Entscheidung: Soll „gesamten Verlauf löschen“ jemals Aufnahmedateien löschen?
   Bis dahin getrennte Aktionen beibehalten.
3. Automatisierte Tests/Harnesses für PlaylistResolver, ICYMetadataReader,
   Recorder, SongExporter und Persistenz aufbauen.
4. Theme-Screenshots als reproduzierbares Layoutgate für normale und schmale
   Fensterbreite etablieren.
5. Öffentliche Präsentation nur separat: Demo-GIF, README-Einstieg und passende
   macOS-/Swift-Verzeichnisse prüfen. Keine Listen für Coding-Agent-Tools nutzen.
6. Sender-Katalog (v1.8.0) manuell in der GUI prüfen: Genre wählen, Probehören
   (Start/Stopp, Fehlerfall), Übernahme inkl. Dubletten-Haken.
7. Sparkle-Update-Kette end-to-end testen: signierter Test-Build mit kleinerer
   `CFBundleVersion` muss v1.8.0+ über „Nach Updates suchen …" finden und
   installieren (Ablauf: docs/sparkle-release.md).
8. Privaten Sparkle-Schlüssel verschlüsselt sichern (liegt nur im
   Login-Schlüsselbund des Release-Rechners; synct nicht über iCloud).

Historische Senderausfälle, bereits implementierte Recorderfunktionen und alte
Theme-Entwürfe sind kein Backlog.
