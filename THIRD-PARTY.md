# Fremdbestandteile & Lizenzen — „Mucke, Baby!"

Stand: 2026-06-07. Diese Datei dokumentiert alle fremden Code-/Daten-/Asset-Bestandteile
und ihre Lizenzlage — als Grundlage für eine mögliche Veröffentlichung (GitHub / Donationware
/ kommerziell). Auslegung bewusst auf den **strengsten Fall (kommerziell)**.

Kurzfazit: Eine kommerzielle Veröffentlichung ist möglich. Einzige echte **Auflage** ist die
**LGPL-Pflicht für VLCKit** (Hinweis + Lizenztext + Relinking-Möglichkeit, durch dynamisches
Linken erfüllt). Marke „Marshall" wurde bereits zu „Stack" entschärft.

---

## 1. VLCKit / libVLC — Audio-Engine

- **Was:** `VLCKit.xcframework` v3.7.3, dynamisch ins App-Bundle gelinkt
  (`Contents/Frameworks/`, ad-hoc signiert). Spielt alle Codecs.
- **Bezug:** `build.sh` lädt einmalig von
  `https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz`
  (gitignored unter `.vendor/`).
- **Lizenz:** **LGPL-2.1-or-later**. Lizenztext liegt bei:
  `.vendor/VLCKit - binary package/COPYING.txt`.
- **Pflichten bei Veröffentlichung (erfüllbar):**
  1. LGPL-Hinweis + Lizenztext mitliefern (diese Datei + COPYING im Release).
  2. Relinking ermöglichen → **durch dynamisches Linken erfüllt** (Nutzer kann das
     Framework ersetzen).
  3. Auf den VLCKit-Quellcode verweisen: <https://code.videolan.org/videolan/VLCKit>.
  4. **Sicherstellen, dass keine GPL-only-Plugins** im Build sind (sonst „infiziert" das
     die App auf GPL). Der offizielle VLCKit-Binärbuild ist LGPL — beim Wechsel auf einen
     Eigenbau prüfen.
- **Kommerziell:** erlaubt unter Einhaltung obiger Punkte.

## 2. Schriften (Fonts) — unkritisch

Alle Theme-Schriften sind **macOS-Systemschriften**, über System-APIs genutzt und **nicht
gebündelt/weiterverteilt** → keine Font-Lizenzpflicht:

- System (San Francisco), Serif (New York), Monospaced (SF Mono) — `.system(...)`.
- American Typewriter, Snell Roundhand (nicht mehr verwendet, s. u.), Noteworthy —
  `Font.custom(...)` greift auf die vom OS installierten Schriften zu.

Hinweis: Snell Roundhand wurde im (ehemals „Marshall", jetzt „Stack") Theme entfernt, weil die
Schreibschrift das Marshall-Logo nachahmte (Trade-Dress). Jetzt Serif.

## 3. KI-generierte Assets — Apache-2.0 (kommerziell frei)

- **Was:** Theme-Texturen (`Resources/themes/<id>/*.png`, 10 Stück) und das App-Icon
  (`Resources/AppIcon.icns`, Master in `icons/`).
- **Erzeugung:** lokal auf eigener Hardware (M5) mit **mflux + Z-Image-Turbo**
  (Tongyi-MAI / Alibaba). Protokoll: `design-proposal/.asset-log.md`, `icons/motifs.md`.
- **Modell-Lizenz:** **Apache-2.0** (Tongyi-MAI/Z-Image-Turbo, HuggingFace) → Modell **und
  dessen Outputs** dürfen kommerziell genutzt, verändert und verteilt werden.
- **Fallback:** Fehlt eine Textur-PNG, zeichnet die App eine prozedurale Canvas-Textur →
  die Texturen sind notfalls entfernbar, ohne dass die App bricht.

## 4. radio-browser.info — Sendersuche

- **Was:** Die „Sender suchen"-Funktion fragt die offene Community-API von
  <https://www.radio-browser.info> ab.
- **Lizenz/Daten:** öffentliche, frei nutzbare Community-Datenbank (Public Domain / frei).
  Nur Abfrage zur Laufzeit, keine Daten mitgeliefert.

## 5. Senderlisten & Streams

- **Stream-URLs** sind Fakten (nicht urheberrechtlich schützbar). Die **Streams selbst**
  gehören den jeweiligen Sendern.
- **Mitgeliefert:** `Resources/seed-stations.example.json` (generische Default-Liste).
  Daniels persönliche Liste (`Resources/seed-stations.json`) ist **gitignored**.
- **Genre-Listen** (`Resources/genre-lists/`): kuratierte Sammlungen.
  *Quelle noch dokumentieren* (radio-browser / manuell zusammengestellt).
- **Aufnahme-Funktion:** nimmt fremde Streams auf → urheberrechtliche Frage des **Nutzers**,
  nicht der Distribution. README warnt; für ein Release Default ggf. auf AUS (TODO D2).

## 6. Marke „Marshall" → „Stack" (erledigt) + Git-Historie

- **Im aktuellen Stand (HEAD):** kein „Marshall"-Markenname mehr im Produkt; Theme heißt
  „Stack", interne ID `stack`, keine Marshall-Schreibschrift (Serif). Tolex-/Gold-Optik ist
  generisch und unkritisch.
- **Kein** echtes Marshall-Logo und **keine** lizenzierte Marshall-Schriftdatei wurde je
  committet (die Kursive war die System-Schrift Snell Roundhand).
- **Git-Historie:** Alte Commits enthalten den Identifier „marshall" (Variablenname/Ordner)
  und KI-Mockups `design-proposal/marshall_amp_design_*.png` (zeigen einen Marshall-Stil-Amp).
  - Rechtlich ist ein Identifier in alten Commits **kein** Markenverstoß (keine Nutzung als
    Produktmarke). Eine History-Bereinigung ist **nicht zwingend**.
  - **Empfehlung für einen sauberen Publish:** die KI-Mockups vor Veröffentlichung aus dem
    Repo nehmen (lokal behalten/gitignore), **und** statt der vollständigen Privat-Historie
    einen **frischen Snapshot** (neue Historie) veröffentlichen. Das umgeht jede
    History-Frage ohne riskanten `git filter-repo` (der alle Hashes umschreibt und das
    interne minipc-Backup bräche).

## 7. Eigenständiger Code

- App-Code ist eine eigene SwiftUI-Implementierung. Funktions-**Nachbau** des Linux-Mint-
  Applets „Radio++" (Features/Ideen sind frei) — **kein** Code/Asset von dort übernommen.
  Die Seed-Liste stammt aus Daniels eigenem Radio++-Export.

---

## Checkliste vor Veröffentlichung

- [ ] LGPL: VLCKit-Lizenztext + Hinweis + Quell-Link ins Release; keine GPL-only-Plugins.
- [ ] KI-Mockups `design-proposal/marshall_amp_design_*.png` entfernen/gitignoren.
- [ ] Frischen Snapshot statt voller Privat-Historie veröffentlichen (umgeht „marshall"-Historie).
- [ ] Genre-Listen-Quelle hier eintragen.
- [ ] Aufnahme-Default für Public erwägen (AUS), README-Warnung (TODO D2).
- [ ] Mehrsprachige README (EN Default + DE), Topics/Description (globale Release-Regel).
