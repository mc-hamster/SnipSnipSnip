#!/usr/bin/env bash
set -euo pipefail

# Select an app window, dialog, or utility panel; menus and system overlays are excluded.

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json capture window --interactive --copy
