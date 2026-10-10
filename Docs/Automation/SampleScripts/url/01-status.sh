#!/usr/bin/env bash
# Readiness reflects the passive macOS gate used by capture services.
set -euo pipefail

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/status"
