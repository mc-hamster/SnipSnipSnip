#!/usr/bin/env bash
set -euo pipefail

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/capture/frontmost-window?output=editor"
