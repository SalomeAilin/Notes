#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_app_path=""
notes_provenance_path=""
notes_device_name=""

usage() {
  cat <<'EOF'
Usage: scripts/verify-ipad-readiness.sh --app <InkNotes.app> --provenance <json> [options]

Read-only verification for a signed InkNotes development app. With
--device-name, it also verifies one physical, paired, available iPad without
printing or persisting hardware identifiers. It never builds, installs,
launches, refreshes profiles, or changes signing assets.

Options:
  --app <path>           Signed .app bundle to verify.
  --provenance <path>    provenance.json created by the signed build script.
  --device-name <name>   Exact CoreDevice user-visible name to verify.
  -h, --help             Show this help.
EOF
}

fail() {
  print -u2 -- "$1"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || fail "--app requires a path"
      notes_app_path="$2"
      shift 2
      ;;
    --provenance)
      (( $# >= 2 )) || fail "--provenance requires a path"
      notes_provenance_path="$2"
      shift 2
      ;;
    --device-name)
      (( $# >= 2 )) || fail "--device-name requires a value"
      notes_device_name="$2"
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

[[ -d "$notes_developer_dir" ]] || fail "Xcode developer directory not found"
[[ -d "$notes_app_path" && "$notes_app_path" == *.app ]] || fail "Signed .app bundle not found"
[[ -f "$notes_provenance_path" ]] || fail "Provenance file not found"

export DEVELOPER_DIR="$notes_developer_dir"
cd "$notes_repository_root"

notes_provenance_schema="$(plutil -extract schemaVersion raw -o - "$notes_provenance_path" 2>/dev/null || true)"
notes_provenance_commit="$(plutil -extract gitCommit raw -o - "$notes_provenance_path" 2>/dev/null || true)"
notes_provenance_clean="$(plutil -extract gitTreeClean raw -o - "$notes_provenance_path" 2>/dev/null || true)"
[[ "$notes_provenance_schema" == "1" ]] || fail "Unsupported provenance schema"
[[ "$notes_provenance_commit" == "$(git rev-parse HEAD)" ]] || fail "App provenance does not match exact Git HEAD"
[[ "$notes_provenance_clean" == "true" ]] || fail "App provenance is not from a clean tree"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || fail "Current worktree is not clean"

codesign --verify --deep --strict "$notes_app_path"
notes_plist_path="$notes_app_path/Info.plist"
[[ -f "$notes_plist_path" ]] || fail "Built Info.plist is missing"
notes_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$notes_plist_path")"
notes_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$notes_plist_path")"
notes_app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$notes_plist_path")"
notes_app_build="$(plutil -extract CFBundleVersion raw -o - "$notes_plist_path")"
notes_minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$notes_plist_path")"
notes_device_family="$(plutil -extract UIDeviceFamily json -o - "$notes_plist_path")"
notes_sdk_name="$(plutil -extract DTSDKName raw -o - "$notes_plist_path")"
notes_xcode_build="$(plutil -extract DTXcodeBuild raw -o - "$notes_plist_path")"
notes_executable_name="$(plutil -extract CFBundleExecutable raw -o - "$notes_plist_path")"
notes_executable_path="$notes_app_path/$notes_executable_name"

[[ "$notes_bundle_id" == "$notes_expected_bundle_id" ]] || fail "Bundle identifier mismatch"
[[ "$notes_device_family" == '[2]' ]] || fail "App is not iPad-only"
[[ -f "$notes_executable_path" ]] || fail "App executable is missing"
[[ "$(lipo -archs "$notes_executable_path")" == "arm64" ]] || fail "App executable is not arm64-only"

notes_cdhash="$(
  codesign -dvvv "$notes_app_path" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -1
)"
notes_signed_team="$(
  codesign -dvv "$notes_app_path" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -1
)"
notes_executable_sha256="$(shasum -a 256 "$notes_executable_path" | awk '{print $1}')"
notes_info_plist_sha256="$(shasum -a 256 "$notes_plist_path" | awk '{print $1}')"

assert_provenance_equal() {
  local notes_key="$1"
  local notes_actual="$2"
  local notes_expected
  notes_expected="$(plutil -extract "$notes_key" raw -o - "$notes_provenance_path" 2>/dev/null || true)"
  [[ "$notes_actual" == "$notes_expected" ]] || fail "Provenance mismatch for $notes_key"
}

assert_provenance_equal bundleIdentifier "$notes_bundle_id"
assert_provenance_equal displayName "$notes_display_name"
assert_provenance_equal appVersion "$notes_app_version"
assert_provenance_equal appBuild "$notes_app_build"
assert_provenance_equal minimumOSVersion "$notes_minimum_os"
[[ "$(plutil -extract deviceFamily json -o - "$notes_provenance_path")" == "$notes_device_family" ]] \
  || fail "Provenance mismatch for deviceFamily"
assert_provenance_equal sdkName "$notes_sdk_name"
assert_provenance_equal xcodeBuild "$notes_xcode_build"
assert_provenance_equal codeDirectoryHash "$notes_cdhash"
assert_provenance_equal executableSHA256 "$notes_executable_sha256"
assert_provenance_equal infoPlistSHA256 "$notes_info_plist_sha256"

notes_embedded_profile="$notes_app_path/embedded.mobileprovision"
[[ -f "$notes_embedded_profile" ]] || fail "Embedded development profile is missing"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-readiness.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT
notes_decoded_profile="$notes_temp_dir/profile.plist"
security cms -D -i "$notes_embedded_profile" -o "$notes_decoded_profile" >/dev/null 2>&1 \
  || fail "Embedded development profile cannot be decoded"

notes_profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$notes_decoded_profile")"
notes_profile_app_identifier="$(
  plutil -extract Entitlements.application-identifier raw -o - "$notes_decoded_profile"
)"
notes_profile_get_task_allow="$(
  plutil -extract Entitlements.get-task-allow raw -o - "$notes_decoded_profile"
)"
notes_profile_expiration="$(plutil -extract ExpirationDate raw -o - "$notes_decoded_profile")"
notes_profile_expiration_epoch="$(
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$notes_profile_expiration" '+%s' 2>/dev/null || true
)"
notes_now_epoch="$(date -u '+%s')"

[[ "$notes_signed_team" == "$notes_profile_team" ]] || fail "Signature and profile teams do not match"
[[ "$notes_profile_app_identifier" == "$notes_profile_team.$notes_bundle_id" ]] \
  || fail "Profile application identifier does not match the app"
[[ "$notes_profile_get_task_allow" == "true" ]] || fail "Profile is not a development profile"
[[ "$notes_profile_expiration_epoch" == <-> ]] || fail "Profile expiration is invalid"
(( notes_profile_expiration_epoch > notes_now_epoch )) || fail "Development profile has expired"
notes_profile_days_remaining=$((
  (notes_profile_expiration_epoch - notes_now_epoch + 86_399) / 86_400
))
if (( notes_profile_days_remaining < 14 )); then
  print -u2 -- "Warning: embedded development profile expires in $notes_profile_days_remaining day(s)"
fi

if [[ -n "$notes_device_name" ]]; then
  [[ "$notes_device_name" =~ "^[[:alnum:]_. -]{1,64}$" ]] \
    || fail "Device name contains unsupported characters"

  device_json_field() {
    local notes_field="$1"
    xcrun devicectl list devices \
      --filter "Name = '$notes_device_name'" \
      --json-output - \
      --omit-deprecated-fields-in-json 2>/dev/null \
      | plutil -extract "result.devices.0.$notes_field" raw -o - - 2>/dev/null
  }

  notes_device_type="$(device_json_field properties.hardware.deviceType || true)"
  [[ -n "$notes_device_type" ]] || fail "No device has the exact requested name"
  if xcrun devicectl list devices \
    --filter "Name = '$notes_device_name'" \
    --json-output - \
    --omit-deprecated-fields-in-json 2>/dev/null \
    | plutil -extract result.devices.1.properties.state.name raw -o - - >/dev/null 2>&1
  then
    fail "More than one device has the requested name"
  fi

  notes_device_reality="$(device_json_field properties.hardware.reality || true)"
  notes_device_platform="$(device_json_field properties.hardware.platform || true)"
  notes_device_pairing="$(device_json_field properties.connection.pairingState || true)"
  notes_device_developer_mode="$(
    device_json_field properties.state.developerModeStatus.enabled.mode || true
  )"
  notes_device_os="$(device_json_field properties.software.osVersionNumber.stringValue || true)"
  notes_device_udid="$(device_json_field properties.hardware.udid || true)"
  notes_device_state="$(
    xcrun devicectl list devices \
      --filter "Name = '$notes_device_name'" \
      --hide-default-columns \
      --columns State \
      --hide-headers 2>/dev/null \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  )"

  [[ "$notes_device_type" == "iPad" ]] || fail "Requested device is not an iPad"
  [[ "$notes_device_reality" == "physical" ]] || fail "Requested device is not physical"
  [[ "$notes_device_platform" == "iOS" ]] || fail "Requested device platform is not iOS"
  [[ "$notes_device_pairing" == "paired" ]] || fail "Requested iPad is not paired"
  [[ "$notes_device_developer_mode" == "1" ]] || fail "Developer Mode is not enabled"
  [[ "$notes_device_state" == available* ]] || fail "Requested iPad is not available"
  [[ "$notes_device_os" == <->(|.<->)(|.<->) ]] || fail "Requested iPad OS version is invalid"
  autoload -Uz is-at-least
  is-at-least "$notes_minimum_os" "$notes_device_os" \
    || fail "Requested iPad OS is below the app minimum"

  notes_profile_contains_device=false
  notes_device_index=0
  while notes_profile_device="$(
    plutil -extract "ProvisionedDevices.$notes_device_index" raw -o - "$notes_decoded_profile" \
      2>/dev/null
  )"; do
    if [[ "$notes_profile_device" == "$notes_device_udid" ]]; then
      notes_profile_contains_device=true
      break
    fi
    (( notes_device_index += 1 ))
  done
  [[ "$notes_profile_contains_device" == true ]] \
    || fail "Embedded profile does not include the requested iPad"

  print -- "Device readiness passed: physical paired iPad, iPadOS $notes_device_os, available"
fi

print -- "Artifact readiness passed: $notes_app_version ($notes_app_build), exact HEAD, signed arm64 iPad app"
