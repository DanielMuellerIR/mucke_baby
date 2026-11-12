# Mediatasten unter Linux: MPRIS nachrüsten

Diese Anleitung beschreibt die Integration in Mucke, Baby! ab 1.10.11 und dient
als Vorlage für weitere Linux-Audioprojekte. Die Anbindung verwendet Qt 6 DBus
und den D-Bus der angemeldeten Benutzersitzung. Sie benötigt keinen
Tastaturtreiber und keinen eigenen globalen Tastatur-Hook.

## Bedienung in Mucke, Baby!

| Taste / MPRIS-Aufruf | Verhalten |
| --- | --- |
| Play/Pause / `PlayPause` | Startet den zuletzt verwendeten Sender, beim ersten Start den ersten aktivierten Sender. Unterbricht laufende Wiedergabe. |
| Pause / `Pause` | Unterbricht laufende Wiedergabe; wiederholtes Pause startet nichts. |
| Play / `Play` | Setzt fort beziehungsweise startet denselben Sender neu. Während Wiedergabe oder Verbindungsaufbau ohne Wirkung. |
| Stop / `Stop` | Beendet Wiedergabe und Empfang. |
| Nächster / Vorheriger Titel | Ohne Wirkung; `CanGoNext` und `CanGoPrevious` sind `false`. |
| Lautstärke / Stumm | Die normalen Systemtasten steuern den Desktop-Audioausgang. MPRIS `Volume` steuert die App-Lautstärke. |

**Live-Radio ohne nutzbaren Timeshift-Puffer:** Play/Pause beendet den Empfang
und meldet `Stopped`. Erneutes Drücken verbindet denselben Sender am aktuellen
Live-Punkt. Der währenddessen gesendete Inhalt geht verloren. Eine laufende
Aufnahme wird dabei abgeschlossen, vorhandene Aufnahmen bleiben erhalten; bei
bewusst aktivierter Aufnahme beginnt mit dem Neustart ein neuer Abschnitt.
Auch ein noch laufender Verbindungsaufbau lässt sich so abbrechen.

**Mit nutzbarem Timeshift-Puffer oder bei lokaler Audiovorschau:** Die Taste
pausiert tatsächlich und meldet `Paused`; Fortsetzen verwendet den vorhandenen
Wiedergabepfad. Die bisherigen Puffergrenzen gelten weiter. Mediatasten schalten
weder Aufnahme noch Timeshift ein. Die sichtbare Timeshift-Pausentaste bleibt
an einen tatsächlich verfügbaren Puffer gebunden.

## Keychron Q1 HE, KDE Plasma und Linux Mint Cinnamon

Die App verarbeitet die vom Desktop zugestellten Medienbefehle, unabhängig von
Tastaturmodell, USB oder Funk. Die verwendete Q1-HE-Belegung muss für die
gewünschte Taste **Media Play/Pause** senden. Ein normales F-Tasten-Ereignis oder
ein Makro mit Leertaste genügt dafür nicht zuverlässig. Die aktive Betriebssystem-
und Fn-Ebene sowie eigene Belegungen anhand des
[Q1-HE-Handbuchs](https://www.keychron.com/pages/keychron-q1-he-user-manual)
beziehungsweise im Keychron Launcher prüfen. Eine Firmwareänderung ist für
MPRIS nicht nötig; die App verändert die Tastaturbelegung nicht.

- **CachyOS mit KDE Plasma:** In den Systemeinstellungen bei den Kurzbefehlen
  für Medienwiedergabe prüfen, ob Play/Pause die gewünschte Taste verwendet.
  Im Medienwiedergabe-Widget Mucke, Baby! als Ziel wählen, falls mehrere Player
  laufen. Plasma wertet unter anderem `CanPlay` und `CanPause` aus.
- **Linux Mint mit Cinnamon:** In den Tastatureinstellungen die Kurzbefehle für
  Ton/Medien prüfen. Cinnamon leitet seine Play-Taste an MPRIS `PlayPause`
  weiter. Andere laufende Player können das Ziel beeinflussen; für die erste
  Prüfung deren Wiedergabe beenden und nur Mucke, Baby! laufen lassen.

Das Fenster darf im Hintergrund oder minimiert sein. Die App muss weiterlaufen
und im selben Benutzer-D-Bus wie der Desktop registriert sein. Nach vollständigem
Beenden startet eine Mediataste die App nicht automatisch. Bei mehreren
Playern bestimmt der Desktop das Ziel; die App beansprucht keine Exklusivität.

Keine zusätzliche globale Belegung auf `playerctl play-pause` einrichten, wenn
der Desktop dieselbe Taste bereits zustellt: Zwei Zustellungen können sich als
Pause und sofortiges Fortsetzen gegenseitig aufheben.

## Diagnose ohne Tastatur

Die folgenden Befehle in einem Terminal der grafischen Benutzersitzung ausführen,
während Mucke, Baby! läuft. Ein SSH-Terminal oder ein eigener `dbus-run-session`
hat nicht automatisch denselben Sitzungsbus.

```sh
# Registrierung und Desktop-Eigenschaften lesen:
gdbus call --session --dest org.mpris.MediaPlayer2.muckebaby \
  --object-path /org/mpris/MediaPlayer2 \
  --method org.freedesktop.DBus.Properties.GetAll org.mpris.MediaPlayer2.Player

# Einmal unterbrechen, dann mit demselben Befehl wieder starten:
gdbus call --session --dest org.mpris.MediaPlayer2.muckebaby \
  --object-path /org/mpris/MediaPlayer2 \
  --method org.mpris.MediaPlayer2.Player.PlayPause

# Zustandsmeldungen beobachten:
gdbus monitor --session --dest org.mpris.MediaPlayer2.muckebaby \
  --object-path /org/mpris/MediaPlayer2
```

Optional mit installiertem [playerctl](https://github.com/altdesktop/playerctl):

```sh
playerctl --list-all
playerctl --player=muckebaby status
playerctl --player=muckebaby play-pause
```

Funktioniert der direkte Aufruf, aber die Taste nicht, liegen die nächsten
Prüfpunkte bei Tastaturbelegung, Desktop-Kurzbefehl und Auswahl des Players.
Fehlt der Busname, zuerst prüfen, ob die richtige App-Version läuft und ob das
Terminal zur selben Sitzung gehört. Die App meldet fehlgeschlagene
MPRIS-Registrierung im Standardfehlerprotokoll. Zusätzliche App-Instanzen verwenden
bei belegtem Namen den Suffix `.instance<PID>`; deren tatsächlichen Namen in
Diagnosebefehlen einsetzen.

## Umsetzung für weitere Audioprojekte

Der Weg lautet: **HID-Medientaste → Desktop-Kurzbefehl → MPRIS/D-Bus →
Transportaktion der Audio-Engine**. Der Desktop übernimmt globale Tastenzustellung
unter X11 beziehungsweise Wayland; ein `QShortcut` im Fenster deckt nur lokalen
Fokus ab. Keine parallelen X11-Grabs oder gerätespezifischen Hooks hinzufügen.

1. Qt DBus einbinden (`find_package(Qt6 REQUIRED COMPONENTS DBus)` und
   `Qt6::DBus` linken). `QDBusConnection::sessionBus()` verwenden, niemals den
   Systembus für Mediensteuerung.
2. Einen stabilen Namen `org.mpris.MediaPlayer2.<app>` und das Objekt
   `/org/mpris/MediaPlayer2` mit Root- und Player-Adaptor registrieren.
   Beide Registrierungsergebnisse prüfen; bei Fehlern bereits belegte eigene
   Ressourcen freigeben. Bei App-Ende die Registrierung freigeben.
3. Die Root-Schnittstelle `org.mpris.MediaPlayer2` bereitstellen, insbesondere
   `Identity`, `DesktopEntry`, `CanRaise`, `CanQuit`, `HasTrackList` sowie die
   unterstützten URI-/MIME-Typen. `DesktopEntry` entspricht dem installierten
   Desktop-Dateinamen ohne `.desktop`.
4. Die Player-Schnittstelle `org.mpris.MediaPlayer2.Player` implementieren:
   `Play`, `Pause`, `PlayPause`, `Stop`, Status, Metadaten, Lautstärke und
   Fähigkeiten. Auch nicht unterstützte Pflichtmethoden anbieten und passend zu
   ihren `Can…`-Eigenschaften wirkungslos lassen. Zeitangaben sind Mikrosekunden;
   `mpris:trackid` ist ein gültiger D-Bus-Objektpfad, kein beliebiger String.
5. `Play` und `Pause` idempotent halten. `Play` darf einen bereits laufenden
   Stream oder Playlist-Download nicht neu starten. `Pause` darf pausiertes
   Audio nicht fortsetzen. Nur `PlayPause` schaltet um. Auch während Auflösung
   und Pufferung ein definiertes Unterbrechungsverhalten vorsehen.
6. Die Audioaktionen auf dem zuständigen Engine-Thread ausführen und dort den
   tatsächlichen Zustand nochmals prüfen. Empfang, Metadaten, Wiederverbindung,
   Decoder und Aufnahme über die vorhandenen Stop-/Pause-Pfade aufräumen.
   Keine zweite Streamverbindung nur für Mediatasten öffnen.
7. Eigenschaften aus derselben Zustandslogik lesen und über
   `org.freedesktop.DBus.Properties.PropertiesChanged` melden, insbesondere
   `PlaybackStatus`, `Metadata`, `CanPlay`, `CanPause` und `CanSeek`.
   Das erste `GetAll` muss schon vor einem Zustandswechsel stimmen.
8. Die Produktentscheidung für Live-Radio ausdrücklich dokumentieren. Die
   MPRIS-Spezifikation beschreibt Pause mit Fortsetzen an derselben Position.
   Mucke, Baby! bietet zusätzlich die oben erklärte Live-Unterbrechung an und
   meldet dafür `CanPause=true`, damit Desktop-Play/Pause bedienbar bleibt;
   der resultierende Status ist ehrlich `Stopped`. Diese Live-Sonderregel
   nicht ungeprüft auf Datei-Player übertragen. Echte Pause setzt eine
   geeignete Engine beziehungsweise einen begrenzten Puffer voraus.

Referenzcode: [MPRIS-Adapter](../linux/src/integration/mpris.cpp),
[Adapterdeklarationen](../linux/src/integration/mpris.h) und
[Engine-Transportaktionen](../linux/src/media/mediaengine.cpp).
Tray und MPRIS verwenden dieselbe Umschaltaktion.

## Prüfung bei der Übernahme

- Auf isoliertem Sitzungsbus: `GetAll`, `PropertiesChanged`, `Play`, wiederholtes
  `Play`, `Pause`, wiederholtes `Pause`, `PlayPause` und `Stop` tatsächlich über
  D-Bus prüfen. Start ohne bisherigen Sender und ohne aktivierte Sender beachten.
- Einen langsamen lokalen Playlist-Server verwenden: wiederholtes `Play` darf
  keinen zweiten Download auslösen; Play/Pause muss abbrechen und wieder starten.
- Mit lokalem Tonstream, temporären Nutzerdaten und privatem Pulse-Null-Ausgang
  prüfen: Live-Unterbrechung, Neustart derselben URL, echte Pufferpause,
  Vorschaupause und ausbleibende unbeabsichtigte Aufnahme.
- Anschließend mit der echten Tastatur unter beiden Ziel-Desktops testen:
  App fokussiert, minimiert, ohne Puffer und mit Puffer; bei mehreren Playern
  das gewählte Ziel prüfen. Ein direkter D-Bus-Test beweist diesen letzten
  Zustellweg noch nicht.

Im Projekt: `ctest --test-dir build/linux -R mpris_test --output-on-failure`
und `dbus-run-session python3 linux/tests/app_runtime_test.py build/linux/mucke-baby`.
Die Laufzeitprüfung verwendet eigene Daten und einen privaten Audio-Server.
Der zusätzliche QtTest-Fall `bufferedAndPreviewTransport` benötigt ein lokales
MP3 ohne Xing-/ID3-Dateikopf in `MUCKE_MPRIS_AUDIO_FIXTURE` und einen ausdrücklich
isolierten `PULSE_SERVER` unter `unix:/tmp/mucke-…`; ohne Opt-in wird er übersprungen.

Prüfstand 2026-11-12: Linux x86-64, Ubuntu 24.04, Qt 6.4.2 und libVLC 3.0.20.
Build, die vier betroffenen CTest-Ziele sowie App-Laufzeitprüfung und zusätzlicher
Puffer-/Vorschautest sind bestanden. Mediatasten und Lautstärkeregler wurden mit
Version 1.10.12 unter CachyOS/KDE manuell bestätigt. Die physische Tastenzustellung
unter Linux Mint/Cinnamon bleibt als [Desktop-Abnahme](../BACKLOG.md) offen.

## Primärquellen

- [MPRIS 2.2](https://specifications.freedesktop.org/mpris/latest/)
  und [Player-Schnittstelle](https://specifications.freedesktop.org/mpris/latest/Player_Interface.html).
- [Qt: QDBusAbstractAdaptor](https://doc.qt.io/qt-6/qdbusabstractadaptor.html).
- [KDE: PlayerContainer](https://github.com/KDE/plasma-workspace/blob/master/libkmpris/playercontainer.cpp),
  insbesondere die Fähigkeitsprüfung vor Play/Pause.
- [Cinnamon: MPRIS-Controller](https://github.com/linuxmint/cinnamon-settings-daemon/blob/master/plugins/media-keys/mpris-controller.c),
  einschließlich der Umsetzung von `Play` auf `PlayPause`.
