#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"

"$SSSCTL" --json export current \
    --output "$OUTPUT_DIR/comparison.html" \
    --format html \
    --appearance styled \
    --overwrite
