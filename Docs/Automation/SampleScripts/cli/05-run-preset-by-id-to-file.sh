#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"
PRESET_ID="${PRESET_ID:-00000000-0000-0000-0000-000000000000}"
FORMAT="${FORMAT:-png}"
OUTPUT_PATH="$OUTPUT_DIR/preset-capture.$FORMAT"

"$SSSCTL" --json presets run --id "$PRESET_ID" --output "$OUTPUT_PATH" --format "$FORMAT" --overwrite
