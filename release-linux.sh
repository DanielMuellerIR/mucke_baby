#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ $# == 0 ]] || { echo 'Linux-Release baut nur ein lokales Archiv; keine Veröffentlichung.' >&2; exit 2; }
bash build-linux.sh
build_dir="${MUCKE_BUILD_DIR:-build/linux}"
ctest --test-dir "$build_dir" --output-on-failure
(cd "$build_dir" && cpack -G TGZ)
echo "RELEASE OK: lokales Archiv in $build_dir"
