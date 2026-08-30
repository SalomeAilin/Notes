#!/bin/zsh
set -euo pipefail
setopt null_glob

notes_repository_root="${0:A:h:h}"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_expected_display_name="InkNotes Dev"
notes_configuration="Debug"
notes_profile_override=""
notes_output_dir=""

usage() {
  cat <<'EOF'
Usage: scripts/build-signed-ipad-app.sh [options]

Build a development-signed, iPad-only app from an exact clean Git HEAD.
The script reads the TeamIdentifier from a local matching provisioning profile;
it never writes a Team ID to the repository and never updates signing assets.

Options:
  --output-dir <path>  DerivedData/provenance output directory.
  --profile <path>     Use one specific local .mobileprovision file.
  -h, --help           Show this help.
EOF
}

fail() {
  print -u2 -- "$1"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --output-dir)
      (( $# >= 2 )) || fail "--output-dir requires a path"
      notes_output_dir="$2"
      shift 2
      ;;
    --profile)
      (( $# >= 2 )) || fail "--profile requires a path"
      notes_profile_override="$2"
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
command -v git >/dev/null || fail "git is required"
command -v security >/dev/null || fail "security is required"
command -v xcodebuild >/dev/null || fail "xcodebuild is required"

export DEVELOPER_DIR="$notes_developer_dir"
cd "$notes_repository_root"

[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "Refusing to build from a dirty worktree"

notes_source_commit="$(git rev-parse HEAD)"
notes_source_commit_short="$(git rev-parse --short=12 HEAD)"
notes_project_build="$({
  rg -o 'CURRENT_PROJECT_VERSION = [0-9]+;' InkNotes.xcodeproj/project.pbxproj \
    | sed -E 's/.* = ([0-9]+);/\1/' \
    | sort -u
} || true)"
[[ "$notes_project_build" == <-> ]] || fail "Debug and Release build numbers must be one integer"

if [[ -z "$notes_output_dir" ]]; then
  notes_output_dir="$notes_repository_root/DerivedData/device-$notes_source_commit_short-build-$notes_project_build"
fi
mkdir -p "$notes_output_dir"
chmod 700 "$notes_output_dir"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-signing-profile.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT

typeset -a notes_profiles
if [[ -n "$notes_profile_override" ]]; then
  [[ -f "$notes_profile_override" ]] || fail "Provisioning profile not found"
  notes_profiles=("$notes_profile_override")
else
  notes_profiles=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision(N)
    "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision(N)
  )
fi
(( ${#notes_profiles[@]} > 0 )) \
  || fail "No local provisioning profiles found; download profiles in Xcode Apple Accounts"

notes_now_epoch="$(date -u '+%s')"
notes_selected_profile=""
notes_selected_team=""
notes_selected_expiration=""
notes_selected_expiration_epoch=0
typeset -A notes_matching_teams
notes_profile_index=0

for notes_profile in "${notes_profiles[@]}"; do
  (( notes_profile_index += 1 ))
  notes_decoded_profile="$notes_temp_dir/profile-$notes_profile_index.plist"
  if ! security cms -D -i "$notes_profile" -o "$notes_decoded_profile" >/dev/null 2>&1; then
    continue
  fi

  notes_team="$(plutil -extract TeamIdentifier.0 raw -o - "$notes_decoded_profile" 2>/dev/null || true)"
  notes_application_identifier="$(
    plutil -extract Entitlements.application-identifier raw -o - "$notes_decoded_profile" \
      2>/dev/null || true
  )"
  notes_platform="$(plutil -extract Platform.0 raw -o - "$notes_decoded_profile" 2>/dev/null || true)"
  notes_get_task_allow="$(
    plutil -extract Entitlements.get-task-allow raw -o - "$notes_decoded_profile" \
      2>/dev/null || true
  )"
  notes_expiration="$(plutil -extract ExpirationDate raw -o - "$notes_decoded_profile" 2>/dev/null || true)"

  [[ "$notes_team" =~ "^[A-Z0-9]{10}$" ]] || continue
  [[ "$notes_application_identifier" == "$notes_team.$notes_expected_bundle_id" ]] || continue
  [[ "$notes_platform" == "iOS" ]] || continue
  [[ "$notes_get_task_allow" == "true" ]] || continue
  plutil -extract ProvisionedDevices.0 raw -o - "$notes_decoded_profile" >/dev/null 2>&1 \
    || continue
  notes_expiration_epoch="$(
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$notes_expiration" '+%s' 2>/dev/null || true
  )"
  [[ "$notes_expiration_epoch" == <-> ]] || continue
  (( notes_expiration_epoch > notes_now_epoch )) || continue

  notes_matching_teams[$notes_team]=1
  if (( notes_expiration_epoch > notes_selected_expiration_epoch )); then
    notes_selected_profile="$notes_profile"
    notes_selected_team="$notes_team"
    notes_selected_expiration="$notes_expiration"
    notes_selected_expiration_epoch="$notes_expiration_epoch"
  fi
done

[[ -n "$notes_selected_profile" ]] \
  || fail "No unexpired iOS development profile matches the stable bundle identifier"
if [[ -z "$notes_profile_override" ]] && (( ${#notes_matching_teams[@]} > 1 )); then
  fail "Matching profiles belong to multiple teams; select one with --profile"
fi

notes_profile_days_remaining=$((
  (notes_selected_expiration_epoch - notes_now_epoch + 86_399) / 86_400
))
if (( notes_profile_days_remaining < 14 )); then
  print -u2 -- "Warning: the selected development profile expires in $notes_profile_days_remaining day(s)"
fi

notes_build_log="$notes_output_dir/build.log"
: > "$notes_build_log"
chmod 600 "$notes_build_log"

if ! xcodebuild \
  -quiet \
  -project InkNotes.xcodeproj \
  -scheme InkNotes \
  -configuration "$notes_configuration" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$notes_output_dir" \
  DEVELOPMENT_TEAM="$notes_selected_team" \
  CODE_SIGN_STYLE=Automatic \
  clean build > "$notes_build_log" 2>&1
then
  fail "Signed iPad build failed; diagnostics are in the local build log"
fi

notes_app_path="$notes_output_dir/Build/Products/$notes_configuration-iphoneos/InkNotes.app"
[[ -d "$notes_app_path" ]] || fail "Signed app bundle was not produced"

notes_final_commit="$(git rev-parse HEAD)"
[[ "$notes_final_commit" == "$notes_source_commit" ]] || fail "Git HEAD changed during the build"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "Worktree changed during the build"

codesign --verify --deep --strict "$notes_app_path"
notes_built_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$notes_app_path/Info.plist")"
notes_built_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$notes_app_path/Info.plist")"
notes_app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$notes_app_path/Info.plist")"
notes_app_build="$(plutil -extract CFBundleVersion raw -o - "$notes_app_path/Info.plist")"
notes_minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$notes_app_path/Info.plist")"
notes_device_family="$(plutil -extract UIDeviceFamily json -o - "$notes_app_path/Info.plist")"
notes_sdk_name="$(plutil -extract DTSDKName raw -o - "$notes_app_path/Info.plist")"
notes_xcode_build="$(plutil -extract DTXcodeBuild raw -o - "$notes_app_path/Info.plist")"
notes_executable_name="$(plutil -extract CFBundleExecutable raw -o - "$notes_app_path/Info.plist")"
notes_executable_path="$notes_app_path/$notes_executable_name"

[[ "$notes_built_bundle_id" == "$notes_expected_bundle_id" ]] || fail "Built bundle identifier drifted"
[[ "$notes_built_display_name" == "$notes_expected_display_name" ]] || fail "Built display name drifted"
[[ "$notes_app_build" == "$notes_project_build" ]] || fail "Built version does not match the project"
[[ "$notes_device_family" == '[2]' ]] || fail "Built app is not iPad-only"
[[ -f "$notes_executable_path" ]] || fail "Built executable is missing"

notes_cdhash="$(
  codesign -dvvv "$notes_app_path" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -1
)"
[[ "$notes_cdhash" =~ "^[0-9a-f]+$" ]] || fail "Unable to read the signed CodeDirectory hash"
notes_executable_sha256="$(shasum -a 256 "$notes_executable_path" | awk '{print $1}')"
notes_info_plist_sha256="$(shasum -a 256 "$notes_app_path/Info.plist" | awk '{print $1}')"

notes_provenance_path="$notes_output_dir/provenance.json"
plutil -create json "$notes_provenance_path"
plutil -insert schemaVersion -integer 1 "$notes_provenance_path"
plutil -insert gitCommit -string "$notes_source_commit" "$notes_provenance_path"
plutil -insert gitTreeClean -bool true "$notes_provenance_path"
plutil -insert bundleIdentifier -string "$notes_built_bundle_id" "$notes_provenance_path"
plutil -insert displayName -string "$notes_built_display_name" "$notes_provenance_path"
plutil -insert appVersion -string "$notes_app_version" "$notes_provenance_path"
plutil -insert appBuild -string "$notes_app_build" "$notes_provenance_path"
plutil -insert minimumOSVersion -string "$notes_minimum_os" "$notes_provenance_path"
plutil -insert deviceFamily -json "$notes_device_family" "$notes_provenance_path"
plutil -insert sdkName -string "$notes_sdk_name" "$notes_provenance_path"
plutil -insert xcodeBuild -string "$notes_xcode_build" "$notes_provenance_path"
plutil -insert codeDirectoryHash -string "$notes_cdhash" "$notes_provenance_path"
plutil -insert executableSHA256 -string "$notes_executable_sha256" "$notes_provenance_path"
plutil -insert infoPlistSHA256 -string "$notes_info_plist_sha256" "$notes_provenance_path"
plutil -insert profileExpirationUTC -string "$notes_selected_expiration" "$notes_provenance_path"
chmod 600 "$notes_provenance_path"

"$notes_repository_root/scripts/verify-ipad-readiness.sh" \
  --app "$notes_app_path" \
  --provenance "$notes_provenance_path"

print -- "Signed iPad app ready: $notes_app_path"
print -- "Provenance ready: $notes_provenance_path"
