#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_PATH="$OUTPUT_DIR/fullscreen-$STAMP.png"

"$SSSCTL" --json capture fullscreen --display current --output "$OUTPUT_PATH" --format png --overwrite
