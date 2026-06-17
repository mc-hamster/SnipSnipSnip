#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
PRESET_NAME="${PRESET_NAME:-Daily Clip}"

"$SSSCTL" --json presets run --name "$PRESET_NAME" --copy
