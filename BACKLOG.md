# Mucke, Baby! — offene Arbeit

1. Seit v1.8.6 geprüft: Recorder-/Export-Laufzeitfälle für MP3, AAC, Ogg/Vorbis
   und Ogg/Opus mit kontrollierten Tonstreams auf macOS 26.6.2. Kern- und
   notarisierte GUI-Ausgaben sind decodierbar; Quellschutz, Abbruch, Sanitizing
   und Temp-Cleanup sind abgedeckt. Codecunterstützung auf macOS 14.2 bleibt
   separat zu prüfen.
2. Entscheidung: Soll „gesamten Verlauf löschen“ jemals Aufnahmedateien löschen?
   Bis dahin getrennte Aktionen beibehalten.
3. Seit v1.8.6 vorhanden: Harnesses für PlaylistResolver, ICYMetadataReader,
   Recorder, SongExporter und Store-Persistenz. Kritische neue Pfade weiterhin
   gezielt ergänzen; das Codecgate steht unter `Tests/export-codecs.py`.
4. Theme-Layoutgate vorhanden: `MUCKE_SHOTS` und `MUCKE_SHOT_W` erzeugen die
   Screenshots aller sieben Themes reproduzierbar. Normale und schmale Breite
   (940/660 Punkte), Standard Hell/Dunkel sind seit v1.8.6 geprüft. Bei relevanten
   UI-Änderungen die betroffenen Zustände erneut prüfen.
5. Öffentliche Präsentation nur separat: Demo-GIF, README-Einstieg und passende
   macOS-/Swift-Verzeichnisse prüfen. Keine Listen für Coding-Agent-Tools nutzen.
6. Seit v1.8.7 geprüft: echte Genre-/Namenssuche, Vorschau Start/Stopp/Neustart,
   Schließen während Vorschau, Übernahme und URL-Dubletten-Haken. Prozesslokale
   Netzwerkfehler belegen die Stream-, Katalog- und Suchfehlermeldungen in der GUI
   auf macOS 26.6.2; verzögerte Fehler-/Stopp-Ereignisse deckt der Player-Harness ab.
7. Sparkle-Update-Kette end-to-end testen: signierter Test-Build mit kleinerer
   `CFBundleVersion` muss v1.8.0+ über „Nach Updates suchen …" finden und
   installieren (Ablauf: docs/sparkle-release.md).
8. Privaten Sparkle-Schlüssel verschlüsselt sichern (liegt nur im
   Login-Schlüsselbund des Release-Rechners; synct nicht über iCloud).
9. Seit v1.8.5 erledigt: die aktuelle notarisierte App ist nach `/Applications`
   installiert. Für den Sparkle-End-to-End-Test ist eine separate ältere
   notarisierte Testkopie nötig.
10. Seit v1.8.4 erledigt: Vorschauereignisse sind durch getrennte VLC-Instanzen
    an ihre Wiedergabe gebunden; verspätete Ereignisse deckt der Player-Harness ab.
11. Seit v1.8.5 erledigt: `add`, `update` und Erstbefüllung prüfen die zentrale
    URL-Policy; der Sendereditor zeigt Validierungsfehler auf Deutsch und Englisch.
    Store-Harness und notarisierter Editor belegen die Schreibgrenzen und den
    Erhalt bestehender Sender.
12. Seit v1.8.7 vorbereitet: `.github/workflows/tests.yml` führt
    `Tests/run-tests.sh` auf einem macOS-Runner aus. Workflow lokal mit actionlint
    geprüft, derselbe Testschritt lokal bestanden. Ausführung auf GitHub bleibt
    bis zur separaten Veröffentlichung ungeprüft.

Historische Senderausfälle, bereits implementierte Recorderfunktionen und alte
Theme-Entwürfe sind kein Backlog.
