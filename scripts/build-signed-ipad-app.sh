#!/bin/zsh
set -euo pipefail
setopt null_glob

notes_repository_root="${0:A:h:h}"
notes_script_path="${0:A}"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_expected_minimum_os="17.0"
notes_configuration="Debug"
notes_profile_override=""
notes_output_dir=""
notes_brand_preview_requested=false
notes_brand_preview_name=""

usage() {
  cat <<'EOF'
Usage: scripts/build-signed-ipad-app.sh [options]

Build a development-signed, iPad-only app from an exact clean Git HEAD.
The script reads the TeamIdentifier from a local matching provisioning profile;
it never writes a Team ID to the repository and never updates signing assets.

Options:
  --output-dir <path>  New DerivedData/device-* direct child for build evidence.
  --profile <path>     Use one specific local .mobileprovision file.
  --brand-preview-name <name>
                       Build a temporary display-name preview without editing Git source.
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
    --brand-preview-name)
      (( $# >= 2 )) || fail "--brand-preview-name requires a value"
      notes_brand_preview_requested=true
      notes_brand_preview_name="$2"
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
command -v plutil >/dev/null || fail "plutil is required"
command -v cmp >/dev/null || fail "cmp is required"
command -v xcodebuild >/dev/null || fail "xcodebuild is required"
[[ -x /usr/bin/perl ]] || fail "Perl is required"
[[ -x /usr/bin/git ]] || fail "Apple Git is required"

export DEVELOPER_DIR="$notes_developer_dir"
umask 077
cd "$notes_repository_root"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-signed-build.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'chmod -R u+w "$notes_temp_dir" 2>/dev/null || true; rm -rf "$notes_temp_dir"' EXIT
mkdir -m 700 "$notes_temp_dir/git-home" "$notes_temp_dir/git-xdg" "$notes_temp_dir/git-tmp"

notes_repository_git() {
  /usr/bin/env -i \
    HOME="$notes_temp_dir/git-home" \
    XDG_CONFIG_HOME="$notes_temp_dir/git-xdg" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="$notes_temp_dir/git-tmp" \
    LC_ALL=C \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects -C "$notes_repository_root" "$@"
}

notes_assert_clean_worktree() {
  local notes_label="$1"
  local notes_status_path="$notes_temp_dir/git-status-$notes_label"
  if ! notes_repository_git -c core.fsmonitor=false -c core.untrackedCache=false \
    status --porcelain=v1 --untracked-files=all > "$notes_status_path"
  then
    fail "Unable to verify the $notes_label worktree state"
  fi
  chmod 600 "$notes_status_path"
  [[ ! -s "$notes_status_path" ]] || fail "Refusing to build from a dirty worktree"
}

notes_assert_clean_worktree initial

notes_source_commit="$(notes_repository_git rev-parse --verify 'HEAD^{commit}')" \
  || fail "Unable to resolve exact Git HEAD without replacement objects"
[[ "$notes_source_commit" =~ "^[0-9a-f]{40}$|^[0-9a-f]{64}$" ]] \
  || fail "Exact Git HEAD is not a full object ID"
notes_source_commit_short="${notes_source_commit[1,12]}"
notes_bootstrap_dir="$notes_temp_dir/committed-scripts"
mkdir -m 700 "$notes_bootstrap_dir"

notes_extract_committed_script() {
  local notes_relative_path="$1"
  local notes_output_path="$2"
  local notes_label="$3"
  if ! notes_repository_git cat-file blob \
    "${notes_source_commit}:${notes_relative_path}" > "$notes_output_path"
  then
    fail "$notes_label is missing from the exact source commit"
  fi
  chmod 600 "$notes_output_path"
  zsh -n "$notes_output_path" || fail "$notes_label is not valid zsh"
}

notes_committed_build_script="$notes_bootstrap_dir/build-signed-ipad-app.sh"
notes_extract_committed_script \
  scripts/build-signed-ipad-app.sh \
  "$notes_committed_build_script" \
  "Signed build script"
cmp -s "$notes_script_path" "$notes_committed_build_script" \
  || fail "Running signed build script differs from the exact source commit"

notes_materializer="$notes_bootstrap_dir/materialize-exact-git-source.zsh"
notes_extract_committed_script \
  scripts/materialize-exact-git-source.zsh \
  "$notes_materializer" \
  "Exact source materializer"

notes_committed_readiness_script="$notes_bootstrap_dir/verify-ipad-readiness.sh"
notes_extract_committed_script \
  scripts/verify-ipad-readiness.sh \
  "$notes_committed_readiness_script" \
  "iPad readiness script"
cmp -s \
  "$notes_repository_root/scripts/verify-ipad-readiness.sh" \
  "$notes_committed_readiness_script" \
  || fail "iPad readiness script differs from the exact source commit"

notes_source_root="$notes_temp_dir/source"
zsh "$notes_materializer" \
  --repository "$notes_repository_root" \
  --commit "$notes_source_commit" \
  --destination "$notes_source_root" \
  || fail "Unable to materialize the exact signed source snapshot"
cmp -s "$notes_source_root/scripts/build-signed-ipad-app.sh" "$notes_committed_build_script" \
  || fail "Materialized signed build script differs from the exact commit"
cmp -s "$notes_source_root/scripts/materialize-exact-git-source.zsh" "$notes_materializer" \
  || fail "Materialized exact source helper differs from the exact commit"
cmp -s "$notes_source_root/scripts/verify-ipad-readiness.sh" "$notes_committed_readiness_script" \
  || fail "Materialized readiness script differs from the exact commit"
if rg -l '^version https://git-lfs.github.com/spec/v1$' "$notes_source_root" >/dev/null 2>&1; then
  fail "Git LFS pointer files are not supported by the signed source snapshot"
fi
if rg 'sourceTree = "?<absolute>"?|path = /|/Users/' \
  "$notes_source_root/InkNotes.xcodeproj/project.pbxproj" >/dev/null 2>&1
then
  fail "Absolute external Xcode source paths are not supported by the signed source snapshot"
fi

notes_display_name_contract="$notes_source_root/scripts/internal-display-name-contract.zsh"
[[ -f "$notes_display_name_contract" && ! -L "$notes_display_name_contract" ]] \
  || fail "Internal display-name contract is missing from the source snapshot"
source "$notes_display_name_contract"
notes_read_internal_placeholder_display_name \
  "$notes_source_root/InkNotes/Info.plist" \
  CFBundleDisplayName \
  "$notes_temp_dir" \
  notes_expected_display_name \
  notes_expected_display_name_raw \
  "Source internal display name" \
  "$notes_expected_bundle_id" \
  || fail "Source internal display name is invalid"

notes_expected_built_display_name="$notes_expected_display_name"
notes_expected_built_display_name_raw="$notes_expected_display_name_raw"
notes_brand_preview=false
if [[ "$notes_brand_preview_requested" == true ]]; then
  notes_brand_preview_candidate_raw="$notes_temp_dir/brand-preview-name.raw"
  print -rn -- "$notes_brand_preview_name" > "$notes_brand_preview_candidate_raw"
  chmod 600 "$notes_brand_preview_candidate_raw"
  notes_validate_internal_display_name_file \
    "$notes_brand_preview_candidate_raw" \
    "Brand preview name" \
    || fail "Brand preview name violates the display-name contract"
  [[ "$notes_brand_preview_name" != "$notes_expected_display_name" ]] \
    || fail "Brand preview name cannot be the internal placeholder"

  notes_preview_plist="$notes_source_root/InkNotes/Info.plist"
  chmod u+w "$notes_preview_plist"
  plutil -replace CFBundleDisplayName -string "$notes_brand_preview_name" \
    "$notes_preview_plist" \
    || fail "Unable to apply the private brand preview overlay"
  chmod a-w "$notes_preview_plist"
  notes_read_validated_display_name \
    "$notes_preview_plist" \
    CFBundleDisplayName \
    "$notes_temp_dir" \
    notes_expected_built_display_name \
    notes_expected_built_display_name_raw \
    "Brand preview display name" \
    || fail "Private brand preview overlay is invalid"
  notes_brand_preview=true
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
notes_repository_git check-ignore -q -- "$notes_output_relative/" \
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
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' \
  clean build > "$notes_build_log_temp" 2>&1
then
  mv "$notes_build_log_temp" "$notes_build_log"
  fail "Signed iPad build failed; diagnostics are in the local build log"
fi
mv "$notes_build_log_temp" "$notes_build_log"

notes_app_path="$notes_output_dir/Build/Products/$notes_configuration-iphoneos/InkNotes.app"
[[ -d "$notes_app_path" ]] || fail "Signed app bundle was not produced"

notes_final_commit="$(notes_repository_git rev-parse --verify 'HEAD^{commit}')"
[[ "$notes_final_commit" == "$notes_source_commit" ]] || fail "Git HEAD changed during the build"
notes_assert_clean_worktree final

codesign --verify --deep --strict "$notes_app_path"
notes_built_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$notes_app_path/Info.plist")"
notes_read_validated_display_name \
  "$notes_app_path/Info.plist" \
  CFBundleDisplayName \
  "$notes_temp_dir" \
  notes_built_display_name \
  notes_built_display_name_raw \
  "Built display name" \
  || fail "Built display name is invalid"
notes_app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$notes_app_path/Info.plist")"
notes_app_build="$(plutil -extract CFBundleVersion raw -o - "$notes_app_path/Info.plist")"
notes_minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$notes_app_path/Info.plist")"
notes_device_family="$(plutil -extract UIDeviceFamily json -o - "$notes_app_path/Info.plist")"
notes_sdk_name="$(plutil -extract DTSDKName raw -o - "$notes_app_path/Info.plist")"
notes_xcode_build="$(plutil -extract DTXcodeBuild raw -o - "$notes_app_path/Info.plist")"
notes_executable_name="$(plutil -extract CFBundleExecutable raw -o - "$notes_app_path/Info.plist")"
notes_executable_path="$notes_app_path/$notes_executable_name"

[[ "$notes_built_bundle_id" == "$notes_expected_bundle_id" ]] || fail "Built bundle identifier drifted"
cmp -s "$notes_built_display_name_raw" "$notes_expected_built_display_name_raw" \
  || fail "Built display name drifted from the permitted source or preview overlay"
notes_assert_no_localized_display_name_override "$notes_app_path" "$notes_temp_dir" "Built app" \
  || fail "Built app display-name localization contract failed"
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
if [[ "$notes_brand_preview" == true ]]; then
  plutil -insert schemaVersion -integer 3 "$notes_provenance_plist"
  plutil -insert brandPreview -bool true "$notes_provenance_plist"
  plutil -insert sourceDisplayName -string "$notes_expected_display_name" \
    "$notes_provenance_plist"
else
  plutil -insert schemaVersion -integer 2 "$notes_provenance_plist"
fi
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

cmp -s "$notes_script_path" "$notes_committed_build_script" \
  || fail "Running signed build script changed during the build"
cmp -s \
  "$notes_repository_root/scripts/verify-ipad-readiness.sh" \
  "$notes_committed_readiness_script" \
  || fail "iPad readiness script changed during the build"
INKNOTES_READINESS_REPOSITORY_ROOT="$notes_repository_root" \
  zsh "$notes_committed_readiness_script" \
    --app "$notes_app_path" \
    --provenance "$notes_provenance_path"

if [[ "$notes_brand_preview" == true ]]; then
  print -- "Brand preview only: display name '$notes_built_display_name'"
  print -- "Git source, app identity, data container, and backup identity were not renamed."
  print -- "This is not trademark, App Store, or public-release clearance."
fi
print -- "Signed iPad app ready: $notes_app_path"
print -- "Provenance ready: $notes_provenance_path"
