#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"
RECT="${RECT:-100,100,640,480}"

"$SSSCTL" --json capture region --rect "$RECT" --output "$OUTPUT_DIR/region.png" --format png --overwrite
