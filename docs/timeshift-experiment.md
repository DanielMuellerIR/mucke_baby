# Experimenteller Zeitversatz

Der normale Player aktiviert diesen Versuch nicht. `TimeshiftBuffer` und
`TimeshiftPlayback` bilden einen isolierten MP3-Pfad; das separate Testbundle
unter `Tests/` bietet den bewussten Einstieg. Es verändert keine Senderliste,
Präferenzen, Verläufe oder dauerhaften Aufnahmen.

## Aufbau und Grenzen

Die ICY-Verbindung entfernt Metadaten aus den Audiobytes. Vollständige MP3-Layer-III-
Frames landen im RAM-Puffer. Seine Standardgrenzen sind 30 Sekunden und 2 MiB
komprimierte Audiobytes; die zuerst erreichte Grenze bestimmt das Fenster.
Parserreste bleiben unter 8 KiB. Frameverwaltung und begrenzte Titeltexte benötigen
zusätzlichen RAM. Die Messung des gesamten Testprozesses schließt VLC und AppKit ein.

Genau ein unveränderlicher Ausschnitt wird für VLC in ein eigenes, zufällig
benanntes temporäres Verzeichnis geschrieben. Er benötigt zusätzlich höchstens
2 MiB. Während einer Pause darf der Empfang alte RAM-Frames entfernen; die aktive
Datei bleibt erhalten. Stop und Live-Rückkehr stoppen zuerst ihren VLC-Leser und
entfernen anschließend den Ausschnitt. Stop entfernt ausschließlich das eigene
Pufferverzeichnis. Unter 10 GiB freiem Speicher beginnt kein Puffer und werden
keine weiteren Audiobytes angenommen. Empfangsfehler beenden den Versuch.

Die Titelzeitachse folgt der aus MP3-Samples berechneten Audiozeit, nicht der
Systemuhr. Ein ICY-Titel gilt ab der nächsten vollständigen Framegrenze. Die
Genauigkeit ist deshalb auf eine Framegrenze begrenzt; MP3-Decoder benötigen
außerdem Anlaufdaten für ihren Bitreservoir. Präziser Seek und Decoder-Vorlauf
sind vor einer allgemeinen Bedienoberfläche weiter abzusichern.

Live benötigt einen VLC-Stream und eine ICY-Verbindung. Verzögerte Wiedergabe
benötigt die lokale Datei und dieselbe ICY-Verbindung. Die Rückkehr zu Live ersetzt
nur die VLC-Quelle. Der Versuch besitzt keinen dauerhaften Recorder.

Der Ausschnitt ist endlich. Meldet VLC nach langer Pause kein Ende, wird der lokale Leser nach zwei Sekunden ohne Zeitfortschritt innerhalb der letzten halben Sekunde kontrolliert beendet. Dieser Schutz wird im Ergebnis gesondert ausgewiesen. Fortlaufendes Lesen neuer
Segmente, Seek, Wiederverbinden, Crash-Cleanup und die gemeinsame Anbindung an
den Recorder gehören zum folgenden Produktionsschritt. Ein pausierter Ausschnitt
bleibt innerhalb seiner ursprünglichen Grenzen abspielbar; neue Empfangsdaten
verlängern ihn nicht. Dieser Versuch verspricht kein fertiges Timeshift-Feature.

## Codecentscheidung

Ein beliebiger Byteschnitt aus einem MP3-Stream kann dekodierbar sein, besitzt
aber keine belastbare Framegrenze. Der Puffer schneidet deshalb an vollständigen
Frames. MPEG-1/2/2.5 Layer III mit tabellierter Bitrate werden erkannt; Free-Format-
MP3, große eingebettete Tags und andere Streamformate sind nicht freigegeben.

ADTS-AAC lässt sich aus vollständigen Frames dekodieren. Ein beliebiger Byteschnitt
kann einen fehlerhaften Anfang liefern. AAC bleibt bis zur Integration eines
ADTS-Parsers außerhalb des Puffers. Ogg/Vorbis und Ogg/Opus benötigen erhaltene
Containerheader und korrekte Paketgrenzen; ein roher Ausschnitt aus der Mitte
liefert im getesteten VLC keinen PCM-Ausgang. Das ist eine Grenze dieses
Segmentkandidaten, keine Einschränkung der normalen VLC-Wiedergabe dieser Codecs.

## Reproduktion

```sh
bash Tests/run-tests.sh
python3 Tests/timeshift-codecs.py /tmp/mucke-timeshift-codecs
python3 Tests/timeshift-probe.py prepare /tmp/mucke-timeshift-proof
```

Die Zielverzeichnisse müssen neu sein. Für den nativen Codecvergleich
`decode` im erzeugten Codecverzeichnis mit `DYLD_FRAMEWORK_PATH` auf dieses
Verzeichnis starten. Er nutzt VLC-Dateiausgabe und benötigt keinen Audioausgang.

Der vollständige native Versuch wird in einer freigegebenen Testumgebung mit
`python3 /tmp/mucke-timeshift-proof/probe.py run /tmp/mucke-timeshift-proof`
gestartet. Er öffnet ausschließlich das eigene Testbundle über LaunchServices;
es findet keine Installation statt. Ein Loopback-Sender liefert synthetische
440-/880-Hz-Abschnitte und ICY-Titel. Der Lauf prüft lokale Wiedergabe, etwa 35 Sekunden
Pause (davon 34 Sekunden kontrollierter Stillstand) mit weiterlaufendem Empfang, Überlauf, Fortsetzen, Ausschnittende,
Titelwechsel, Live-Rückkehr und vollständiges Schließen aller Verbindungen.
`cleanup` mit demselben Prüfroot ist separat und wiederholt ausführbar.

`result.json`, `timeline.json`, `connections.json`, `memory.json` und fünf
Zustandsbilder dokumentieren den Lauf. `played-excerpt.mp3` dient dem unabhängigen
Decoder-/Titelvergleich. CoreAudio-Ausgangsstatus und decodierbares Audio ersetzen
keinen menschlichen Hörtest. Ein solcher Test sowie die reale Mindest-macOS-
Prüfung müssen im jeweiligen Abnahmeprotokoll ausdrücklich gekennzeichnet bleiben.

## Hörprüfung des Experiments

Am 2026-10-18 wurde der vollständige MP3-Versuch unter macOS 26.7.1 gehört:
Live-Ton, Fortsetzen nach der Pause und Live-Rückkehr waren hörbar; es wurden
keine Aussetzer bemerkt. An den Frequenzwechseln knackte der Testton. Die
synthetische Quelle schaltet ihre Sinusfrequenz mit einem Phasensprung um;
diese Signalsprünge sind auch in der unabhängig decodierten Quelle enthalten.
Der lokale Ausschnitt ist bytegleich zur entsprechenden Quellstelle.

Der begrenzte EOF-Schutz war auch in diesem Lauf nötig. Die Hörprüfung bestätigt
den endlichen Versuch; präzise Decoder-Vorläufe, vollständige Endpositionen und
nahtlose Übergänge eines fortlaufenden Segmentlesers sind damit weiterhin nicht
freigegeben. Die reale Laufzeitprüfung unter macOS 14.2 bleibt ausstehend.
