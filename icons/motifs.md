# App-Icon — 8 Motive (zur Auswahl)

Stand: 2026-06-07. Generierung läuft auf **M5** (mflux + Z-Image-Turbo, frei/kein Token).
Je Motiv **3 Varianten** über Seeds `7 42 123`. Quelle des Verfahrens:
`~/git/theplan/knowledge/local-llm/image-gen.md`.

Gemeinsamer Stil-Rahmen (in jedem Prompt): *macOS app icon, rounded-square (squircle),
centered, flat vector with subtle depth and soft inner shadow, no text, no letters,
high contrast, crisp at small sizes, 1024×1024*.

| # | id | Motiv | Idee / Stimmung | Farbwelt |
|---|----|-------|-----------------|----------|
| 1 | wave-burst   | Broadcast-Wellen | konzentrische Funkwellen aus einem Punkt — „on air" | Magenta→Violett auf Anthrazit |
| 2 | retro-dial   | Vintage-Tuner | Skala + Zeiger eines alten Radios, modern-skeuomorph | Bernstein/Amber auf Charcoal |
| 3 | speaker-cone | Lautsprecher | Speaker-Membran mit Schall-Ringen, druckvoll | Neon-Cyan/Pink auf Schwarz |
| 4 | antenna      | Sendemast | geometrischer Funkturm strahlt Wellen ab, minimal | Blau-Verlauf |
| 5 | vinyl-pulse  | Platte→Welle | Schallplatte morpht in eine Soundwave, Club-Feel | Violett→Cyan |
| 6 | eq-bars      | Equalizer | EQ-Balken energetisch, Techno | Orange→Pink |
| 7 | headphones   | Kopfhörer | schlanke Kopfhörer + kleiner Sendebogen, freundlich | Teal/Türkis |
| 8 | bolt-wave    | Hardstyle-Blitz | Blitz als Soundwave (Hardstyle-Energie), dezenter IT-Akzent | Grün-Weiß-Rot auf Dunkel |

Erzeugen: `bash icons/generate-on-m5.sh` (auf M5). Ergebnis in `icons/candidates/`.
Danach Auswahl → finales Motiv als `.icns` bauen (Skript-Hinweis am Ende der generate-Datei).
