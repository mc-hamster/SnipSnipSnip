#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"

"$SSSCTL" --json capture fullscreen --private --output "$OUTPUT_DIR/private-capture.png" --format png --overwrite
