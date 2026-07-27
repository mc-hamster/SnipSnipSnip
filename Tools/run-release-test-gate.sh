#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"

project="$REPOSITORY_ROOT/SnipSnipSnip.xcodeproj"
scheme="SnipSnipSnip"
configuration="Debug"
destination="platform=macOS,arch=arm64"
derived_data="${TMPDIR:-/tmp}/SnipSnipSnipReleaseTestGate"
result_bundle=""
app_name="SnipSnipSnip"
ui_test_runner_name="SnipSnipSnipUITests-Runner.app"
only_testing=()

usage() {
  printf '%s\n' \
    "Usage: $(basename "$0") [options]" \
    "" \
    "Build and run the complete app-hosted macOS XCTest matrix serially." \
    "" \
    "Options:" \
    "  --project PATH          Xcode project. Default: SnipSnipSnip.xcodeproj" \
    "  --scheme NAME           Shared scheme. Default: SnipSnipSnip" \
    "  --configuration NAME    Test configuration. Default: Debug" \
    "  --destination VALUE     xcodebuild destination." \
    "  --derived-data PATH     DerivedData directory." \
    "  --result-bundle PATH    Optional .xcresult output path." \
    "  --only-testing TARGET   Restrict the run; may be repeated." \
    "  -h, --help              Show this help."
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || fail "$option requires a value."
}

while (($# > 0)); do
  case "$1" in
    --project)
      require_value "$1" "${2:-}"
      project="$2"
      shift 2
      ;;
    --scheme)
      require_value "$1" "${2:-}"
      scheme="$2"
      shift 2
      ;;
    --configuration)
      require_value "$1" "${2:-}"
      configuration="$2"
      shift 2
      ;;
    --destination)
      require_value "$1" "${2:-}"
      destination="$2"
      shift 2
      ;;
    --derived-data)
      require_value "$1" "${2:-}"
      derived_data="$2"
      shift 2
      ;;
    --result-bundle)
      require_value "$1" "${2:-}"
      result_bundle="$2"
      shift 2
      ;;
    --only-testing)
      require_value "$1" "${2:-}"
      only_testing+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -d "$project" ]] || fail "Xcode project not found: $project"

if pgrep -x "$app_name" >/dev/null 2>&1; then
  fail "$app_name is already running. Quit the user-owned copy before running app-hosted tests."
fi

common_arguments=(
  -project "$project"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "$destination"
  -derivedDataPath "$derived_data"
  CODE_SIGNING_ALLOWED=YES
)

signing_mode="development"
signing_identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
valid_development_identities="$(
  /usr/bin/grep '"Apple Development:' <<< "$signing_identities" |
    /usr/bin/grep -v 'CSSMERR_' || true
)"
if [[ -n "$valid_development_identities" ]]; then
  printf '%s\n' "Using an installed Apple Development identity for app-hosted tests."
else
  signing_mode="adhoc"
  common_arguments+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
  )
  printf '%s\n' "No Apple Development identity found; using certificate-free ad-hoc test signing."
fi

for test_environment_name in \
  SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS \
  SSS_REQUIRE_EXTERNAL_HTML_BROWSERS \
  SSS_GOOGLE_CHROME_BINARY \
  SSS_FIREFOX_BINARY
do
  test_environment_value="$(/usr/bin/printenv "$test_environment_name" 2>/dev/null || true)"
  if [[ -n "$test_environment_value" ]]; then
    common_arguments+=("$test_environment_name=$test_environment_value")
  fi
done

test_selection_arguments=()
if ((${#only_testing[@]} > 0)); then
  for target in "${only_testing[@]}"; do
    test_selection_arguments+=("-only-testing:$target")
  done
fi

build_arguments=(
  build-for-testing
  "${common_arguments[@]}"
)
if ((${#test_selection_arguments[@]} > 0)); then
  build_arguments+=("${test_selection_arguments[@]}")
fi

printf 'Building the serial app-hosted test products in %s\n' "$derived_data"
xcodebuild "${build_arguments[@]}"

ui_test_runner="$derived_data/Build/Products/$configuration/$ui_test_runner_name"
[[ -d "$ui_test_runner" ]] || fail "UI test runner not found: $ui_test_runner"

# Xcode generates a sandboxed UI-test wrapper. An ad-hoc signature cannot carry
# that wrapper entitlement on a certificate-free CI runner, so the process can
# stall in libsecinit before XCTest starts. The wrapper is developer-only and
# never ships. Re-signing only its outer bundle without entitlements preserves
# the signed nested XCTest payload while allowing the serial runner to launch.
if [[ "$signing_mode" == "adhoc" ]]; then
  codesign --force --sign - --timestamp=none "$ui_test_runner"
fi
codesign --verify --deep --strict "$ui_test_runner"

if pgrep -x "$app_name" >/dev/null 2>&1; then
  fail "$app_name started outside XCTest. Quit it before continuing the release gate."
fi

test_arguments=(
  test-without-building
  "${common_arguments[@]}"
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
)
if ((${#test_selection_arguments[@]} > 0)); then
  test_arguments+=("${test_selection_arguments[@]}")
fi

if [[ -n "$result_bundle" ]]; then
  test_arguments+=(-resultBundlePath "$result_bundle")
fi

xcodebuild "${test_arguments[@]}"
