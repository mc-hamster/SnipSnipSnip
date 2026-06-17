#!/usr/bin/env bash
set -euo pipefail

PRESET_ID="${PRESET_ID:-00000000-0000-0000-0000-000000000000}"

open "snipsnipsnip://v1/presets/run?id=$PRESET_ID&output=editor"
