#!/bin/zsh
set -euo pipefail
setopt null_glob

notes_repository_root="${0:A:h:h}"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_expected_display_name="InkNotes Dev"
notes_expected_minimum_os="17.0"
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
  --output-dir <path>  New DerivedData/device-* direct child for build evidence.
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
command -v rg >/dev/null || fail "ripgrep is required"
command -v security >/dev/null || fail "security is required"
command -v shasum >/dev/null || fail "shasum is required"
command -v tar >/dev/null || fail "tar is required"
command -v xcodebuild >/dev/null || fail "xcodebuild is required"

export DEVELOPER_DIR="$notes_developer_dir"
umask 077
cd "$notes_repository_root"

[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "Refusing to build from a dirty worktree"

notes_source_commit="$(git rev-parse HEAD)"
notes_source_commit_short="$(git rev-parse --short=12 "$notes_source_commit")"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-signed-build.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'chmod -R u+w "$notes_temp_dir" 2>/dev/null || true; rm -rf "$notes_temp_dir"' EXIT
notes_source_root="$notes_temp_dir/source"
mkdir "$notes_source_root"
if git ls-tree -r "$notes_source_commit" \
  | awk '$1 == "120000" || $1 == "160000" { found = 1 } END { exit(found ? 0 : 1) }'
then
  fail "Tracked symbolic links and submodules are not supported by the signed source snapshot"
fi
if git ls-tree -r --name-only "$notes_source_commit" \
  | awk -F/ '$NF == ".gitattributes" { found = 1 } END { exit(found ? 0 : 1) }'
then
  fail "Committed .gitattributes requires an explicit signed snapshot review"
fi
git archive --format=tar "$notes_source_commit" | tar -xf - -C "$notes_source_root"
if rg -l '^version https://git-lfs.github.com/spec/v1$' "$notes_source_root" >/dev/null 2>&1; then
  fail "Git LFS pointer files are not supported by the signed source snapshot"
fi
if rg 'sourceTree = "?<absolute>"?|path = /|/Users/' \
  "$notes_source_root/InkNotes.xcodeproj/project.pbxproj" >/dev/null 2>&1
then
  fail "Absolute external Xcode source paths are not supported by the signed source snapshot"
fi
chmod -R a-w "$notes_source_root"

notes_project_file="$notes_source_root/InkNotes.xcodeproj/project.pbxproj"
notes_project_build="$({
  rg -o 'CURRENT_PROJECT_VERSION = [0-9]+;' "$notes_project_file" \
    | sed -E 's/.* = ([0-9]+);/\1/' \
    | sort -u
} || true)"
notes_project_version="$({
  rg -o 'MARKETING_VERSION = [^;]+;' "$notes_project_file" \
    | sed -E 's/.* = ([^;]+);/\1/' \
    | sort -u
} || true)"
[[ "$notes_project_build" == <-> ]] || fail "Debug and Release build numbers must be one integer"
[[ "$notes_project_version" == <->.<->.<-> ]] \
  || fail "Debug and Release marketing versions must be one semantic version"

notes_allowed_output_root="$notes_repository_root/DerivedData"
[[ ! -L "$notes_allowed_output_root" ]] || fail "DerivedData must not be a symbolic link"
mkdir -p "$notes_allowed_output_root"
notes_allowed_output_root="${notes_allowed_output_root:A}"
if [[ -z "$notes_output_dir" ]]; then
  notes_output_dir="$(
    mktemp -d "$notes_allowed_output_root/device-$notes_source_commit_short-build-$notes_project_build.XXXXXX"
  )"
else
  notes_output_dir="${notes_output_dir:A}"
  [[ "$notes_output_dir" == "$notes_allowed_output_root"/device-* ]] \
    || fail "Output directory must be a device-* directory under repository DerivedData"
  [[ "${notes_output_dir:h}" == "$notes_allowed_output_root" ]] \
    || fail "Output directory must be a direct child of repository DerivedData"
  [[ ! -e "$notes_output_dir" && ! -L "$notes_output_dir" ]] \
    || fail "Output directory already exists; choose a new device-* directory"
  mkdir "$notes_output_dir"
fi
[[ "$notes_output_dir" == "$notes_allowed_output_root"/device-* ]] \
  || fail "Output directory must be a device-* directory under repository DerivedData"
[[ "${notes_output_dir:h}" == "$notes_allowed_output_root" ]] \
  || fail "Output directory must be a direct child of repository DerivedData"
[[ "${notes_output_dir:A}" == "$notes_allowed_output_root"/device-* ]] \
  || fail "Output directory escaped repository DerivedData"
[[ -O "$notes_output_dir" ]] || fail "Output directory is not owned by the current user"
notes_output_relative="${notes_output_dir#$notes_repository_root/}"
git check-ignore -q -- "$notes_output_relative/" \
  || fail "Output directory must remain ignored by Git"
chmod 700 "$notes_output_dir"

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
notes_selected_uuid=""
notes_selected_sha256=""
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
  notes_profile_uuid="$(plutil -extract UUID raw -o - "$notes_decoded_profile" 2>/dev/null || true)"
  notes_profile_sha256="$(shasum -a 256 "$notes_profile" | awk '{print $1}')"
  notes_expiration="$(plutil -extract ExpirationDate raw -o - "$notes_decoded_profile" 2>/dev/null || true)"

  [[ "$notes_team" =~ "^[A-Z0-9]{10}$" ]] || continue
  [[ "$notes_profile_uuid" =~ "^[0-9A-Fa-f-]{36}$" ]] || continue
  [[ "$notes_profile_sha256" =~ "^[0-9a-f]{64}$" ]] || continue
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
    notes_selected_uuid="$notes_profile_uuid"
    notes_selected_sha256="$notes_profile_sha256"
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
notes_build_log_temp="$(mktemp "$notes_output_dir/.build-log.XXXXXX")"
chmod 600 "$notes_build_log_temp"

if ! xcodebuild \
  -quiet \
  -project "$notes_source_root/InkNotes.xcodeproj" \
  -scheme InkNotes \
  -configuration "$notes_configuration" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$notes_output_dir" \
  DEVELOPMENT_TEAM="$notes_selected_team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development' \
  PROVISIONING_PROFILE_SPECIFIER="$notes_selected_uuid" \
  clean build > "$notes_build_log_temp" 2>&1
then
  mv "$notes_build_log_temp" "$notes_build_log"
  fail "Signed iPad build failed; diagnostics are in the local build log"
fi
mv "$notes_build_log_temp" "$notes_build_log"

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
[[ "$notes_app_version" == "$notes_project_version" ]] || fail "Built marketing version drifted"
[[ "$notes_app_build" == "$notes_project_build" ]] || fail "Built version does not match the project"
[[ "$notes_minimum_os" == "$notes_expected_minimum_os" ]] || fail "Built minimum OS version drifted"
[[ "$notes_device_family" == '[2]' ]] || fail "Built app is not iPad-only"
[[ -f "$notes_executable_path" ]] || fail "Built executable is missing"

notes_embedded_profile="$notes_app_path/embedded.mobileprovision"
[[ -f "$notes_embedded_profile" ]] || fail "Embedded development profile is missing"
notes_actual_profile_sha256="$(shasum -a 256 "$notes_embedded_profile" | awk '{print $1}')"
[[ "$notes_actual_profile_sha256" =~ "^[0-9a-f]{64}$" ]] \
  || fail "Unable to hash the embedded development profile"
notes_actual_profile_plist="$notes_temp_dir/embedded-profile.plist"
security cms -D -i "$notes_embedded_profile" -o "$notes_actual_profile_plist" >/dev/null 2>&1 \
  || fail "Embedded development profile cannot be decoded"
notes_actual_profile_uuid="$(plutil -extract UUID raw -o - "$notes_actual_profile_plist" 2>/dev/null || true)"
notes_actual_profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$notes_actual_profile_plist" 2>/dev/null || true)"
notes_actual_profile_app_identifier="$(
  plutil -extract Entitlements.application-identifier raw -o - "$notes_actual_profile_plist" \
    2>/dev/null || true
)"
notes_actual_profile_platform="$(plutil -extract Platform.0 raw -o - "$notes_actual_profile_plist" 2>/dev/null || true)"
notes_actual_profile_get_task_allow="$(
  plutil -extract Entitlements.get-task-allow raw -o - "$notes_actual_profile_plist" \
    2>/dev/null || true
)"
notes_actual_profile_expiration="$(plutil -extract ExpirationDate raw -o - "$notes_actual_profile_plist" 2>/dev/null || true)"
notes_actual_profile_expiration_epoch="$(
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$notes_actual_profile_expiration" '+%s' \
    2>/dev/null || true
)"

[[ "$notes_actual_profile_uuid" == "$notes_selected_uuid" ]] \
  || fail "Embedded profile does not match the selected profile"
[[ "$notes_actual_profile_sha256" == "$notes_selected_sha256" ]] \
  || fail "Embedded profile bytes do not match the selected profile"
[[ "$notes_actual_profile_team" == "$notes_selected_team" ]] \
  || fail "Embedded profile team does not match the selected profile"
[[ "$notes_actual_profile_app_identifier" == "$notes_actual_profile_team.$notes_built_bundle_id" ]] \
  || fail "Embedded profile application identifier does not match the app"
[[ "$notes_actual_profile_platform" == "iOS" ]] || fail "Embedded profile platform is not iOS"
[[ "$notes_actual_profile_get_task_allow" == "true" ]] \
  || fail "Embedded profile is not a development profile"
plutil -extract ProvisionedDevices.0 raw -o - "$notes_actual_profile_plist" >/dev/null 2>&1 \
  || fail "Embedded development profile has no provisioned devices"
[[ "$notes_actual_profile_expiration_epoch" == <-> ]] \
  || fail "Embedded profile expiration is invalid"
(( notes_actual_profile_expiration_epoch > notes_now_epoch )) \
  || fail "Embedded development profile has expired"

notes_cdhash="$(
  codesign -dvvv "$notes_app_path" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -1
)"
[[ "$notes_cdhash" =~ "^[0-9a-f]+$" ]] || fail "Unable to read the signed CodeDirectory hash"
notes_executable_sha256="$(shasum -a 256 "$notes_executable_path" | awk '{print $1}')"
notes_info_plist_sha256="$(shasum -a 256 "$notes_app_path/Info.plist" | awk '{print $1}')"

notes_provenance_path="$notes_output_dir/provenance.json"
notes_provenance_plist="$notes_temp_dir/provenance.plist"
notes_provenance_json="$notes_temp_dir/provenance.json"
plutil -create xml1 "$notes_provenance_plist"
plutil -insert schemaVersion -integer 2 "$notes_provenance_plist"
plutil -insert gitCommit -string "$notes_source_commit" "$notes_provenance_plist"
plutil -insert gitTreeClean -bool true "$notes_provenance_plist"
plutil -insert bundleIdentifier -string "$notes_built_bundle_id" "$notes_provenance_plist"
plutil -insert displayName -string "$notes_built_display_name" "$notes_provenance_plist"
plutil -insert appVersion -string "$notes_app_version" "$notes_provenance_plist"
plutil -insert appBuild -string "$notes_app_build" "$notes_provenance_plist"
plutil -insert minimumOSVersion -string "$notes_minimum_os" "$notes_provenance_plist"
plutil -insert deviceFamily -json "$notes_device_family" "$notes_provenance_plist"
plutil -insert sdkName -string "$notes_sdk_name" "$notes_provenance_plist"
plutil -insert xcodeBuild -string "$notes_xcode_build" "$notes_provenance_plist"
plutil -insert codeDirectoryHash -string "$notes_cdhash" "$notes_provenance_plist"
plutil -insert executableSHA256 -string "$notes_executable_sha256" "$notes_provenance_plist"
plutil -insert infoPlistSHA256 -string "$notes_info_plist_sha256" "$notes_provenance_plist"
plutil -insert embeddedProfileSHA256 -string "$notes_actual_profile_sha256" "$notes_provenance_plist"
plutil -insert profileExpirationUTC -string "$notes_actual_profile_expiration" "$notes_provenance_plist"
plutil -convert json -o "$notes_provenance_json" "$notes_provenance_plist"
chmod 600 "$notes_provenance_json"
mv "$notes_provenance_json" "$notes_provenance_path"

"$notes_repository_root/scripts/verify-ipad-readiness.sh" \
  --app "$notes_app_path" \
  --provenance "$notes_provenance_path"

print -- "Signed iPad app ready: $notes_app_path"
print -- "Provenance ready: $notes_provenance_path"
