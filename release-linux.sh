#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ $# == 0 ]] || { echo 'Linux-Release baut nur ein lokales Archiv; keine Veröffentlichung.' >&2; exit 2; }
bash build-linux.sh
build_dir="${MUCKE_BUILD_DIR:-build/linux}"
ctest --test-dir "$build_dir" --output-on-failure
(cd "$build_dir" && cpack -G TGZ)
IFS= read -r package_name < "$build_dir/linux-package-name.txt"
(cd "$build_dir" && sha256sum -- "$package_name" > SHA256SUMS)
echo "RELEASE OK: $build_dir/$package_name und SHA256SUMS"
