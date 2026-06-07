#!/usr/bin/env bash
# App-Icon-Kandidaten erzeugen — AUF M5 ausfuehren (mflux + Z-Image-Turbo).
# 8 Motive x 3 Seeds = 24 Bilder nach icons/candidates/.
# Verfahren/Modell: ~/git/theplan/knowledge/local-llm/image-gen.md
#
# Voraussetzung auf M5: mflux installiert (`mflux-generate` im PATH).
# Falls dein mflux-Z-Image-Aufruf anders heisst, MODEL/STEPS unten anpassen.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${MFLUX_MODEL:-z-image-turbo}"   # bei Bedarf ueberschreiben
STEPS="${MFLUX_STEPS:-8}"
SEEDS="7 42 123"                        # 3 Varianten je Motiv (Seeds batchen)
OUT="icons/candidates"
mkdir -p "$OUT"

STYLE="macOS app icon, rounded-square squircle, centered, flat vector with subtle depth and soft inner shadow, no text, no letters, high contrast, crisp, 1024x1024"

gen () {  # gen <id> <motif-prompt>
  local id="$1"; shift
  local prompt="$1, ${STYLE}"
  echo "==> $id"
  mflux-generate \
    --model "$MODEL" \
    --prompt "$prompt" \
    --width 1024 --height 1024 \
    --steps "$STEPS" \
    --seed $SEEDS \
    --output "$OUT/${id}.png"
}

gen wave-burst   "concentric radio broadcast waves emanating from a glowing center dot, on-air signal, magenta to violet gradient on charcoal"
gen retro-dial   "vintage radio tuning dial with frequency scale and needle, modern skeuomorphic, warm amber on dark charcoal"
gen speaker-cone "stylized loudspeaker driver cone with concentric sound rings, punchy, neon cyan and pink rim light on black"
gen antenna      "geometric broadcast antenna mast emitting radio waves, minimal, blue gradient"
gen vinyl-pulse  "a vinyl record morphing into a sound waveform, electronic club vibe, violet to cyan gradient"
gen eq-bars      "energetic equalizer bars rising, techno music, orange to pink gradient on dark"
gen headphones   "sleek modern headphones with a small broadcast signal arc, friendly, teal and turquoise"
gen bolt-wave    "a lightning bolt shaped as an audio waveform, hardstyle energy, subtle green white red accents on dark background"

echo
echo "Fertig -> $OUT  (8 Motive x 3 Seeds)."
echo "Auswahl treffen, dann finales PNG (1024) so zu .icns machen:"
echo '  mkdir MacRadio.iconset'
echo '  for s in 16 32 64 128 256 512 1024; do sips -z $s $s gewaehlt.png --out MacRadio.iconset/icon_${s}x${s}.png; done'
echo '  iconutil -c icns MacRadio.iconset -o ../Resources/MacRadio.icns'
echo '  # dann in Info.plist  <key>CFBundleIconFile</key><string>MacRadio</string>  + build.sh kopiert die .icns'
