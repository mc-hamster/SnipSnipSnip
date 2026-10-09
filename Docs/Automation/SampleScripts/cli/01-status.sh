#!/usr/bin/env bash
# Readiness reflects the passive macOS gate used by capture services.
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json status
