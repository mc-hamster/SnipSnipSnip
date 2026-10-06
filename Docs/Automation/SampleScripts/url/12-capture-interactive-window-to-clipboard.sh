#!/usr/bin/env bash
set -euo pipefail

# Select an app window, dialog, or utility panel; menus and system overlays are excluded.

open "snipsnipsnip://v1/capture/window?output=clipboard"
