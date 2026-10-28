#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Linux ]] || { echo 'Linux-Build bitte auf einem Linux-Rechner ausführen.' >&2; exit 1; }
build_dir="${MUCKE_BUILD_DIR:-build/linux}"
jobs="${MUCKE_BUILD_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'MUCKE_BUILD_JOBS muss positiv sein.' >&2; exit 2; }
cmake -S linux -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DMUCKE_BUILD_TESTS=ON "$@"
cmake --build "$build_dir" --parallel "$jobs"
echo "BUILD OK: $build_dir/mucke-baby"
