# Fremdbestandteile und Lizenzen

Stand: 2026-10-28. Der eigene Swift- und C++-Quellcode von Mucke, Baby! steht
unter der [MIT-Lizenz](LICENSE). Für Fremdbestandteile gelten deren eigene
Lizenztexte. Linux und macOS verwenden unterschiedliche Systembibliotheken.

## macOS: VLCKit / libVLC

- Dynamisch eingebundenes **VLCKit 3.7.3**, LGPL-2.1-or-later. Das Framework liegt
  im App-Bundle unter `Contents/Frameworks/` und bleibt austauschbar.
- `build.sh` lädt das gepinnte Archiv von VideoLAN und prüft dessen SHA-256.
  Es liefert den vollständigen Lizenztext aus dem Archiv unter
  `Contents/Resources/Licenses/VLCKit.txt` mit.
- [VLCKit-Quellcode](https://code.videolan.org/videolan/VLCKit) und
  [VLC-Quellcode](https://code.videolan.org/videolan/vlc).
  Bei eigenen Framework-Builds müssen auch die Lizenzen der eingebundenen
  Codec-Plugins berücksichtigt werden.

## macOS: Sparkle

- Dynamisch eingebundenes **Sparkle 2.9.4**, MIT mit weiteren permissiven
  Hinweisen einzelner Bestandteile.
- `build.sh` lädt die offizielle, SHA-256-geprüfte Binärdistribution. Deren
  vollständige Lizenzdatei liegt in der App unter
  `Contents/Resources/Licenses/Sparkle.txt`.
- [Sparkle-Quellcode und Lizenz](https://github.com/sparkle-project/Sparkle).

## Linux: Systembibliotheken und Exportwerkzeug

Das Linux-Archiv enthält keine Kopien von Qt, libVLC, VLC-Plugins, libpulse oder
FFmpeg. Die App verwendet dynamische Bibliotheken und das FFmpeg-Programm aus
Distributionspaketen. Diese Bestandteile bleiben unabhängig austauschbar.

| Bestandteil | Lizenz und Bezug |
| --- | --- |
| Qt 6 Core, Gui, Widgets, Network, DBus | Die verwendeten Module sind unter LGPL-3.0 verfügbar; Qt bietet außerdem GPL- und kommerzielle Lizenzen. [Lizenzübersicht](https://doc.qt.io/qt-6/licensing.html), [Qt-Base-Quellcode](https://code.qt.io/cgit/qt/qtbase.git/). |
| libVLC 3 | LGPL-2.1-or-later. [Quellcode](https://code.videolan.org/videolan/vlc). Die Plugins haben zusätzliche, vom jeweiligen Distributionspaket dokumentierte Lizenzen. |
| libpulse | LGPL-2.1-or-later. [PulseAudio-Quellcode](https://gitlab.freedesktop.org/pulseaudio/pulseaudio). |
| nlohmann/json | MIT; als Header beim Kompilieren eingebunden. [Quellcode](https://github.com/nlohmann/json). Der vollständige [Lizenztext](linux/packaging/nlohmann-json-LICENSE.MIT) liegt auch im Archiv und in der Benutzerinstallation. |
| FFmpeg | Separates Programm für lokale Exporte. Je nach Distributionsbuild gelten LGPL- oder GPL-Bedingungen. [Quellcode und Lizenzübersicht](https://ffmpeg.org/legal.html). |

Qt Test wird nur für Regressionstests verwendet und nicht in das ausgelieferte
Programm eingebunden. Für eigene Distributionspakete gelten zusätzlich die
Lizenz- und Quellcodepflichten der darin tatsächlich mitgelieferten Komponenten.

## Schriften und Bilder

macOS verwendet seine Systemschriften. Linux verwendet unter anderem DejaVu
und die Desktop-Standardschrift. Diese Systemschriften werden nicht mitgeliefert.
Für das Linux-Fanzine-Theme sind unveränderte Regular- und Bold-Dateien von
**Zilla Slab** eingebettet, Copyright 2017 The Mozilla Foundation, unter der
**SIL Open Font License 1.1**. [Quelle, Commit und Prüfsummen](linux/resources/fonts/README.md)
sowie der [vollständige Lizenztext](linux/resources/fonts/OFL.txt) liegen im Repo.
Archiv und Benutzerinstallation enthalten zusätzlich `ZillaSlab-OFL.txt`.

App-Icon und Theme-Texturen wurden lokal mit mflux und Z-Image-Turbo erzeugt.
Das [Modell Z-Image-Turbo](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo)
steht laut Modellkarte unter Apache-2.0. Diese Modelllizenz ist keine gesonderte
Lizenzzuweisung für generierte Bilder. Das Projekt enthält keine Modellgewichte.
Fehlende Hintergrundtexturen können durch die Darstellung im Code ersetzt werden.

## Sender, Katalog und externe Dienste

Die generische Startliste steht in `Resources/seed-stations.example.json`.
Eine optionale persönliche lokale Startliste ist gitignored und wird nicht
veröffentlicht. Der Linux-Bau bindet ausschließlich die generische Liste ein.
Die Genre-Listen enthalten handkuratierte Streamadressen und Anzeigenamen.
Streams und Musikinhalte bleiben Sache ihrer jeweiligen Rechteinhaber.

Die Katalogsuche nutzt [radio-browser.info](https://www.radio-browser.info)
zur Laufzeit mit einem versionsbezogenen User-Agent. Die
[API-Dokumentation](https://docs.radio-browser.info/) beschreibt die Nutzung;
ein Katalogdatenbestand wird nicht mitgeliefert.

Musiklinks öffnen Apple Music beziehungsweise Spotify. Songtextabfragen nutzen
unter Linux nach einer ausdrücklichen Aktion lyrics.ovh. Die macOS-Erkennung
nutzt Apple ShazamKit. Es werden keine SDKs dieser Musik- oder Songtextdienste
im Linux-Archiv mitgeliefert.

Aufnahme ist standardmäßig aus. Die App erteilt keine Rechte an fremden Streams
oder exportierter Musik.

## Herkunft des eigenen Codes

Die Idee wurde vom Linux-Mint-Applet Radio++ angeregt. Es wurden weder Code noch
Assets von Radio++ übernommen. macOS verwendet eine eigene SwiftUI-Oberfläche;
Linux eine eigene C++-/Qt-Widgets-Oberfläche.
