#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"

"$SSSCTL" --json export current --output "$OUTPUT_DIR/current-screenshot.png" --format png --overwrite
