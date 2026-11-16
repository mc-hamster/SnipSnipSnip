#!/usr/bin/env bash
# Guide automation is Pro-only; App Store requests return proFeatureRequired.
# Guide needs Screen Recording and Accessibility; narration also needs Microphone.
# Set up access in the app first. Unattended requests fail without showing permission UI.
set -euo pipefail
open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/guide/start?target=window"
