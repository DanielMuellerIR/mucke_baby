# Offene Produkt- und Laufzeitprüfungen

- Codecabhängige Aufnahme, M4A-Export, Zeitversatz und Musikerkennung auf
  macOS 14.2 prüfen. Die vorhandenen kontrollierten Codec- und GUI-Fixtures
  liefen auf neueren macOS-Versionen.
- Zeitversatz beim echten Systemschlaf mit pausiertem Produktionspuffer
  prüfen. Die Handler sind über den Player-Harness abgedeckt. Ogg/Vorbis,
  Ogg/Opus und FLAC benötigen für Zeitversatz eine eigene Containerstrategie.
  [Formatgrenzen und Tests](docs/timeshift-buffer.md)
- Austausch von Merklisteneinträgen mit Erkennungs- und Ausgabeherkunft
  zwischen macOS und iPhone mit dem Format V3 prüfen. Die älteren Empfänger
  müssen die Integrität neuer Bibliotheken schützen.
  [Austauschformate](docs/library-exchange.md)
- Physische Medientasten unter Linux Mint mit Cinnamon bei fokussierter und
  minimierter App abnehmen. CachyOS/KDE wurde am 2026-11-12 manuell geprüft.
  [Linux-Medientasten](docs/linux-media-keys.md)
- Die macOS-CI-Konfiguration auf dem gehosteten Runner ausführen.
  Der lokale Test deckt Headless-Harnesses, vollständigen Build und Bundle-Gate ab.
- Demo-GIF und Projektvorstellung auf den Stand beider Plattformen bringen.
