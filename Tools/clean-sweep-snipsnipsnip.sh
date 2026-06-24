#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BUNDLE_ID="com.oontz.SnipSnipSnip"
readonly DEFAULT_SHARE_EXTENSION_BUNDLE_ID="com.oontz.SnipSnipSnip.ShareExtension"
readonly DEFAULT_APP_NAME="SnipSnipSnip"

bundle_id="$DEFAULT_BUNDLE_ID"
share_extension_bundle_id="$DEFAULT_SHARE_EXTENSION_BUNDLE_ID"
app_name="$DEFAULT_APP_NAME"
mode="dry-run"
remove_apps=false
remove_derived_data=false
reset_tcc=true
reset_background_items=false
verbose=false
original_arg_count=$#
original_args=("$@")

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Clean local SnipSnipSnip state so permission onboarding can be tested from a
fresh macOS privacy/settings baseline. Dry-run is the default.

Options:
  --apply                    Delete/reset matching state.
  --dry-run                  Print actions without changing anything. Default.
  --bundle-id ID             Main app bundle ID. Default: $DEFAULT_BUNDLE_ID
  --share-extension-id ID    Share extension bundle ID. Default: $DEFAULT_SHARE_EXTENSION_BUNDLE_ID
  --app-name NAME            App display/name prefix. Default: $DEFAULT_APP_NAME
  --remove-apps              Also remove installed app bundles found in common app locations.
  --derived-data             Also remove matching Xcode DerivedData directories.
  --skip-tcc                 Do not run tccutil privacy resets.
  --reset-background-items   Run 'sfltool resetbtm'. This resets macOS background
                             item state broadly, not only SnipSnipSnip.
  -v, --verbose              Print skipped paths and successful commands.
  -h, --help                 Show this help.

Examples:
  Tools/clean-sweep-snipsnipsnip.sh
  Tools/clean-sweep-snipsnipsnip.sh --apply
  Tools/clean-sweep-snipsnipsnip.sh --apply --remove-apps --derived-data

Notes:
  - Screen Recording, Accessibility, Camera, Microphone, Apple Events, and
    System Audio privacy rows are reset with tccutil when the current macOS
    recognizes those service names.
  - Some privacy resets may require quitting SnipSnipSnip first. Accessibility
    and Screen Recording prompts usually appear again on the next app launch or
    first protected capture attempt.
  - If SnipSnipSnip is running, this script requests a normal quit and clicks
    the in-app Quit confirmation with System Events when the dialog appears.
    This avoids sending SIGTERM/SIGKILL into Xcode debug sessions.
  - macOS does not provide a narrow public command for removing only one app's
    background-item/login-item record. Use --reset-background-items only on a
    throwaway test Mac or when a broad reset is acceptable.
EOF
}

log() {
  printf '%s\n' "$*"
}

debug() {
  if [[ "$verbose" == true ]]; then
    log "$@"
  fi
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

quote_path() {
  printf '%q' "$1"
}

run_cmd() {
  if [[ "$mode" == "dry-run" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi

  if "$@"; then
    debug "[ok] $*"
    return 0
  fi

  return 1
}

remove_path() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    run_cmd rm -rf "$path"
  else
    debug "[skip] missing $(quote_path "$path")"
  fi
}

delete_defaults_domain() {
  local domain="$1"

  if [[ "$mode" == "dry-run" ]]; then
    run_cmd defaults delete "$domain"
    return 0
  fi

  if defaults delete "$domain" >/dev/null 2>&1; then
    debug "[ok] defaults delete $domain"
  else
    debug "[skip] defaults domain not present: $domain"
  fi
}

reset_tcc_service() {
  local service="$1"
  local target_bundle_id="$2"

  if [[ "$mode" == "dry-run" ]]; then
    run_cmd tccutil reset "$service" "$target_bundle_id"
    return 0
  fi

  if tccutil reset "$service" "$target_bundle_id" >/dev/null 2>&1; then
    debug "[ok] tccutil reset $service $target_bundle_id"
  else
    debug "[skip] tccutil service unavailable or not reset: $service $target_bundle_id"
  fi
}

remove_glob_matches() {
  local pattern="$1"
  local found=false
  local path

  while IFS= read -r -d '' path; do
    found=true
    remove_path "$path"
  done < <(compgen -G "$pattern" | while IFS= read -r path; do printf '%s\0' "$path"; done)

  if [[ "$found" == false ]]; then
    debug "[skip] no matches for $(quote_path "$pattern")"
  fi
}

osascript_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

click_quit_confirmation() {
  local escaped_app_name
  escaped_app_name="$(osascript_escape "$app_name")"

  osascript <<EOF
tell application "System Events"
  if not (exists process "$escaped_app_name") then return
  tell process "$escaped_app_name"
    repeat 20 times
      repeat with candidateWindow in windows
        if exists button "Quit" of candidateWindow then
          click button "Quit" of candidateWindow
          return
        end if
      end repeat
      delay 0.25
    end repeat
  end tell
end tell
EOF
}

quit_running_app() {
  if ! pgrep -x "$app_name" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$mode" == "dry-run" ]]; then
    log "Requesting normal quit for running $app_name and clicking the confirmation if it appears."
    run_cmd defaults write "$bundle_id" SSSConfirmsBeforeQuitting -bool false
    run_cmd osascript -e "tell application id \"$bundle_id\" to quit"
    log "[dry-run] System Events would click the in-app Quit button if the confirmation appears."
    return 0
  fi

  log "Requesting normal quit for running $app_name."
  defaults write "$bundle_id" SSSConfirmsBeforeQuitting -bool false >/dev/null 2>&1 || true

  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 &
  local quit_request_pid=$!

  sleep 0.75
  if pgrep -x "$app_name" >/dev/null 2>&1; then
    if ! click_quit_confirmation >/dev/null 2>&1; then
      log "Could not click the quit confirmation with System Events."
      log "Grant Accessibility to the terminal app running this script, or close $app_name manually and rerun Clean Sweep."
      return 1
    fi
  fi

  wait "$quit_request_pid" >/dev/null 2>&1 || true

  local attempts=0
  while pgrep -x "$app_name" >/dev/null 2>&1 && ((attempts < 20)); do
    sleep 0.25
    attempts=$((attempts + 1))
  done

  if pgrep -x "$app_name" >/dev/null 2>&1; then
    log "$app_name is still running after the quit request."
    log "Close it manually and rerun Clean Sweep, or turn off Confirm Before Quitting in the app before running this script."
    return 1
  fi
}

print_apply_command() {
  local script_path="$0"
  local args=("--apply")
  local arg

  if ((original_arg_count > 0)); then
    for arg in "${original_args[@]}"; do
      case "$arg" in
        --apply|--dry-run)
          ;;
        *)
          args+=("$arg")
          ;;
      esac
    done
  fi

  printf '  '
  printf '%q ' "$script_path"
  printf '%q ' "${args[@]}"
  printf '\n'
}

print_dry_run_summary() {
  if [[ "$reset_background_items" == true ]]; then
    log "Dry run safety: NOT fully app-scoped safe."
    log "Reason: --reset-background-items would run 'sfltool resetbtm', which resets macOS background item state broadly."
  else
    log "Dry run safety: SAFE app-scoped cleanup."
    log "The planned cleanup targets SnipSnipSnip bundle IDs, app-owned files, app preferences, and app privacy rows."
  fi

  if [[ "$remove_apps" == true ]]; then
    log "Includes optional app bundle removal from common application locations."
  fi

  if [[ "$remove_derived_data" == true ]]; then
    log "Includes optional matching Xcode DerivedData removal."
  fi

  log "Run this to perform the full cleanup:"
  print_apply_command
}

while (($#)); do
  case "$1" in
    --apply)
      mode="apply"
      ;;
    --dry-run)
      mode="dry-run"
      ;;
    --bundle-id)
      shift
      [[ $# -gt 0 ]] || fail "--bundle-id requires a value"
      bundle_id="$1"
      ;;
    --share-extension-id)
      shift
      [[ $# -gt 0 ]] || fail "--share-extension-id requires a value"
      share_extension_bundle_id="$1"
      ;;
    --app-name)
      shift
      [[ $# -gt 0 ]] || fail "--app-name requires a value"
      app_name="$1"
      ;;
    --remove-apps)
      remove_apps=true
      ;;
    --derived-data)
      remove_derived_data=true
      ;;
    --skip-tcc)
      reset_tcc=false
      ;;
    --reset-background-items)
      reset_background_items=true
      ;;
    -v|--verbose)
      verbose=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

readonly home_library="$HOME/Library"
readonly temp_dir="${TMPDIR:-/tmp}"

log "SnipSnipSnip Clean Sweep"
log "Mode: $mode"
log "Bundle ID: $bundle_id"
log "Share extension ID: $share_extension_bundle_id"
log ""

quit_running_app

log "Deleting preferences."
delete_defaults_domain "$bundle_id"
delete_defaults_domain "$share_extension_bundle_id"
remove_path "$home_library/Preferences/$bundle_id.plist"
remove_path "$home_library/Preferences/$share_extension_bundle_id.plist"
remove_glob_matches "$home_library/Preferences/ByHost/$bundle_id.*.plist"
remove_glob_matches "$home_library/Preferences/ByHost/$share_extension_bundle_id.*.plist"

log "Deleting app-owned support, cache, logs, saved-state, and container files."
remove_path "$home_library/Application Support/$app_name"
remove_path "$home_library/Caches/$bundle_id"
remove_path "$home_library/Caches/$share_extension_bundle_id"
remove_path "$home_library/HTTPStorages/$bundle_id"
remove_path "$home_library/HTTPStorages/$share_extension_bundle_id"
remove_path "$home_library/Logs/$app_name"
remove_path "$home_library/Saved Application State/$bundle_id.savedState"
remove_path "$home_library/WebKit/$bundle_id"
remove_path "$home_library/Cookies/$bundle_id.binarycookies"
remove_path "$home_library/Application Scripts/$bundle_id"
remove_path "$home_library/Application Scripts/$share_extension_bundle_id"
remove_path "$home_library/Containers/$bundle_id"
remove_path "$home_library/Containers/$share_extension_bundle_id"
remove_path "$home_library/Group Containers/$bundle_id"
remove_path "$home_library/Group Containers/$share_extension_bundle_id"
remove_path "$home_library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$bundle_id.sfl2"
remove_path "$home_library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$share_extension_bundle_id.sfl2"
remove_glob_matches "$temp_dir/$app_name-*"
remove_glob_matches "$temp_dir/${app_name}Video-*"
remove_glob_matches "$temp_dir/${app_name}-export-*"

if [[ "$reset_tcc" == true ]]; then
  log "Resetting macOS privacy decisions with tccutil."
  reset_tcc_service All "$bundle_id"

  for service in \
    Accessibility \
    ScreenCapture \
    Microphone \
    Camera \
    AppleEvents \
    SystemAudioCapture \
    ListenEvent \
    PostEvent
  do
    reset_tcc_service "$service" "$bundle_id"
  done

  reset_tcc_service AppleEvents "$share_extension_bundle_id"
fi

if [[ "$reset_background_items" == true ]]; then
  log "Resetting macOS background item state broadly with sfltool resetbtm."
  run_cmd sfltool resetbtm || true
else
  log "Skipping broad background-item reset. Pass --reset-background-items only if acceptable."
fi

if [[ "$remove_apps" == true ]]; then
  log "Removing installed app bundles from common locations."
  remove_path "/Applications/$app_name.app"
  remove_path "$HOME/Applications/$app_name.app"
  remove_glob_matches "$HOME/Applications/$app_name*.app"
fi

if [[ "$remove_derived_data" == true ]]; then
  log "Removing matching DerivedData directories."
  remove_glob_matches "$home_library/Developer/Xcode/DerivedData/$app_name-*"
fi

log "Flushing preference cache."
run_cmd killall cfprefsd || true

log ""
if [[ "$mode" == "dry-run" ]]; then
  print_dry_run_summary
else
  log "Clean sweep complete. Reopen $app_name to retest onboarding."
fi
