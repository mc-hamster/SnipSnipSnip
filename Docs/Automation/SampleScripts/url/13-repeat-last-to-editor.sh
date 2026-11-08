#!/usr/bin/env bash
set -euo pipefail

# Repeating a selected app dialog or utility panel retains that window target.

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/repeat-last?output=editor"
