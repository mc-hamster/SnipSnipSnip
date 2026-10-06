#!/usr/bin/env bash
set -euo pipefail

# Region and Window use the same fresh window bounds to identify the target under the pointer.

# Select an app window, dialog, or utility panel; menus and system overlays are excluded.

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json capture window --interactive --copy
