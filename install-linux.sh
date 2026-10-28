#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Linux ]] || { echo 'Linux-Installation bitte auf einem Linux-Rechner ausführen.' >&2; exit 1; }
build_dir="${MUCKE_BUILD_DIR:-build/linux}"
prefix="${MUCKE_INSTALL_PREFIX:-$HOME/.local}"
if [[ "${1:-}" == --no-build ]]; then
    shift
else
    bash build-linux.sh
fi
[[ $# == 0 ]] || { echo 'Aufruf: install-linux.sh [--no-build]' >&2; exit 2; }
exec python3 linux/tools/install.py --binary "$build_dir/mucke-baby" --prefix "$prefix" --source-root "$PWD"
