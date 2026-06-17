#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
RECT="${RECT:-100,100,640,480}"

"$SSSCTL" --json capture region --rect "$RECT" --open-editor
