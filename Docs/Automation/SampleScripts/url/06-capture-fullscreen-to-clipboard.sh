#!/usr/bin/env bash
set -euo pipefail

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/capture/fullscreen?display=current&output=clipboard"
