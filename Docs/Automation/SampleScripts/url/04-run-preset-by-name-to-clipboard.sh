#!/usr/bin/env bash
set -euo pipefail

PRESET_NAME="${PRESET_NAME:-Daily Clip}"
encoded_name="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$PRESET_NAME")"

open "snipsnipsnip://v1/presets/run?name=$encoded_name&output=clipboard"
