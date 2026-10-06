#!/usr/bin/env bash
set -euo pipefail

# Drag a region, or click an outlined app window, dialog, or utility panel.

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json capture region --interactive --open-editor
