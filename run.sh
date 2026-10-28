#!/usr/bin/env bash
# Baut und startet "Mucke, Baby!".
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
if [[ "$(uname -s)" == Linux ]]; then
    exec "${MUCKE_BUILD_DIR:-build/linux}/mucke-baby" "$@"
fi
open "build/Mucke, Baby!.app"
