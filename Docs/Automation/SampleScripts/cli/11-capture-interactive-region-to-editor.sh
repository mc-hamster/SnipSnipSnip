#!/usr/bin/env bash
set -euo pipefail

# Region and Window use the same fresh window bounds to identify the target under the pointer.

# Drag a region, or click an outlined app window, dialog, or utility panel.

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json capture region --interactive --open-editor
