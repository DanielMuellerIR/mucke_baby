#!/usr/bin/env bash
# Baut und startet "Mucke, Baby!".
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
open "build/Mucke, Baby!.app"
