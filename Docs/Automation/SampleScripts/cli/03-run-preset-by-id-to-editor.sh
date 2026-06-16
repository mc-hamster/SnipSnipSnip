#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
PRESET_ID="${PRESET_ID:-00000000-0000-0000-0000-000000000000}"

"$SSSCTL" --json presets run --id "$PRESET_ID" --open-editor
