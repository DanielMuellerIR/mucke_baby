#!/usr/bin/env bash
set -euo pipefail
[[ $# == 0 ]] || { echo 'Aufruf: ./install.sh (MUCKE_INSTALL_PREFIX überschreibt ~/.local)' >&2; exit 2; }
archive_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$archive_dir/install.py" --binary "$archive_dir/bin/mucke-baby" \
  --prefix "${MUCKE_INSTALL_PREFIX:-$HOME/.local}" --source-root "$archive_dir"
