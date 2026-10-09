#!/usr/bin/env bash
# Guide needs Screen Recording and Accessibility; narration also needs Microphone.
# Set up access in the app first. Unattended requests fail without showing permission UI.
set -euo pipefail
SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
"$SSSCTL" --json guide start --target window
