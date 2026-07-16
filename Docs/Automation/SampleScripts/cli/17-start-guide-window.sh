#!/usr/bin/env bash
set -euo pipefail
SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
"$SSSCTL" --json guide start --target window
