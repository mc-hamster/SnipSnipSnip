#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
SSS_DOCUMENT="${SSS_DOCUMENT:-$HOME/Downloads/example.sss}"

"$SSSCTL" --json open --file "$SSS_DOCUMENT" --output "$OUTPUT_DIR/opened-document.png" --format png --overwrite
