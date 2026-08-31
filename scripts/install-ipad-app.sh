#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_script_path="${0:A}"
notes_readiness_script="$notes_repository_root/scripts/verify-ipad-readiness.sh"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_app_path=""
notes_provenance_path=""
notes_device_name=""
notes_should_launch=false

usage() {
  cat <<'EOF'
Usage: scripts/install-ipad-app.sh --app <InkNotes.app> --provenance <json> --device-name <name> [--launch]

Verifies an exact-provenance signed development app and one exact, available
iPad before performing an in-place install. The installed app is then read
back by bundle identifier, version, build, and display name. Launch is opt-in.

Options:
  --app <path>           Signed .app bundle to install.
  --provenance <path>    provenance.json created by the signed build script.
  --device-name <name>   Exact CoreDevice user-visible iPad name.
  --launch               Launch only after install and identity readback pass.
  -h, --help             Show this help without touching a device.
EOF
}

fail_usage() {
  print -u2 -- "$1"
  exit 2
}

fail_preflight() {
  print -u2 -- "$1"
  exit 2
}

fail_readiness() {
  print -u2 -- "$1"
  exit 3
}

fail_install_unknown() {
  print -u2 -- "$1"
  exit 4
}

fail_readback() {
  print -u2 -- "$1"
  exit 5
}

fail_launch() {
  print -u2 -- "$1"
  exit 6
}

fail_device_trust() {
  print -u2 -- "$1"
  exit 7
}

fail_postcondition() {
  print -u2 -- "$1"
  exit 8
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || fail_usage "--app requires a path"
      notes_app_path="$2"
      shift 2
      ;;
    --provenance)
      (( $# >= 2 )) || fail_usage "--provenance requires a path"
      notes_provenance_path="$2"
      shift 2
      ;;
    --device-name)
      (( $# >= 2 )) || fail_usage "--device-name requires a value"
      notes_device_name="$2"
      shift 2
      ;;
    --launch)
      notes_should_launch=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail_usage "Unknown option: $1"
      ;;
  esac
done

[[ -d "$notes_app_path" && "$notes_app_path" == *.app && ! -L "$notes_app_path" ]] \
  || fail_preflight "Signed .app bundle not found or unsafe"
[[ -f "$notes_provenance_path" && ! -L "$notes_provenance_path" ]] \
  || fail_preflight "Provenance file not found or unsafe"
[[ -n "$notes_device_name" ]] || fail_usage "--device-name is required"
[[ "$notes_device_name" =~ "^[[:alnum:]_. -]{1,64}$" ]] \
  || fail_usage "Device name contains unsupported characters"
notes_device_name_lower="${notes_device_name:l}"
[[ "$notes_device_name_lower" != *"the user did not explicitly trust the provisioning profile"* \
  && "$notes_device_name_lower" != *"profile has not been explicitly trusted by the user"* ]] \
  || fail_usage "Device name contains reserved diagnostic wording"
[[ -d "$notes_repository_root" && ! -L "$notes_repository_root" ]] \
  || fail_preflight "Repository directory not found or unsafe"
[[ -f "$notes_script_path" && -f "$notes_readiness_script" ]] \
  || fail_preflight "Required iPad scripts are missing"
[[ -d "$notes_developer_dir" ]] || fail_preflight "Xcode developer directory not found"
command -v jq >/dev/null || fail_preflight "jq is required"
command -v plutil >/dev/null || fail_preflight "plutil is required"
command -v cmp >/dev/null || fail_preflight "cmp is required"
[[ -x /usr/bin/xcrun ]] || fail_preflight "Apple xcrun is required"
[[ -x /usr/bin/stat ]] || fail_preflight "Apple stat is required"
[[ -x /usr/bin/git ]] || fail_preflight "Apple Git is required"
[[ -x /usr/bin/perl ]] || fail_preflight "Perl is required"

notes_app_parent="$(cd "${notes_app_path:h}" 2>/dev/null && pwd -P)" \
  || fail_preflight "Signed app parent directory is unavailable"
notes_app_path="$notes_app_parent/${notes_app_path:t}"
notes_provenance_parent="$(cd "${notes_provenance_path:h}" 2>/dev/null && pwd -P)" \
  || fail_preflight "Provenance parent directory is unavailable"
notes_provenance_path="$notes_provenance_parent/${notes_provenance_path:t}"

export DEVELOPER_DIR="$notes_developer_dir"
umask 077
cd "$notes_repository_root"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-install.XXXXXX")" \
  || fail_preflight "Private temporary directory could not be created"
chmod 700 "$notes_temp_dir" || fail_preflight "Private temporary directory could not be secured"
trap 'rm -rf "$notes_temp_dir"' EXIT
mkdir -m 700 "$notes_temp_dir/git-home" "$notes_temp_dir/git-xdg" "$notes_temp_dir/git-tmp"

notes_prepare_private_file() {
  local notes_private_path="$1"
  : > "$notes_private_path"
  chmod 600 "$notes_private_path"
}

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
  local notes_status_path="$notes_temp_dir/git-status"
  if ! notes_repository_git -c core.fsmonitor=false -c core.untrackedCache=false \
    status --porcelain=v1 --untracked-files=all > "$notes_status_path"
  then
    return 1
  fi
  chmod 600 "$notes_status_path"
  [[ ! -s "$notes_status_path" ]]
}

notes_exact_head_matches_provenance() {
  local notes_current_head
  notes_current_head="$(notes_repository_git rev-parse --verify 'HEAD^{commit}')" \
    || return 1
  [[ "$notes_current_head" == "$notes_provenance_commit" ]]
}

notes_provenance_commit="$(
  plutil -extract gitCommit raw -o - "$notes_provenance_path" 2>/dev/null || true
)"
[[ "$notes_provenance_commit" =~ "^[0-9a-f]{40}$" ]] \
  || fail_readiness "Provenance Git commit is invalid; install was not attempted"
notes_exact_head_matches_provenance \
  || fail_readiness "App provenance does not match exact Git HEAD; install was not attempted"
notes_assert_clean_worktree \
  || fail_readiness "Current worktree is not clean; install was not attempted"

notes_committed_source_dir="$notes_temp_dir/committed-source"
mkdir -m 700 "$notes_committed_source_dir"
notes_committed_install_script="$notes_committed_source_dir/install-ipad-app.sh"
if ! notes_repository_git cat-file blob \
  "${notes_provenance_commit}:scripts/install-ipad-app.sh" \
  > "$notes_committed_install_script"
then
  fail_readiness "Installer is missing from the provenance commit; install was not attempted"
fi
chmod 600 "$notes_committed_install_script"
zsh -n "$notes_committed_install_script" \
  || fail_readiness "Committed installer is invalid; install was not attempted"
cmp -s "$notes_script_path" "$notes_committed_install_script" \
  || fail_readiness "Running installer differs from the provenance commit; install was not attempted"

notes_readiness_output="$notes_temp_dir/readiness-output"
notes_device_handoff_path="$notes_temp_dir/device-selector"
notes_prepare_private_file "$notes_readiness_output"
notes_prepare_private_file "$notes_device_handoff_path"
set +e
INKNOTES_READINESS_REPOSITORY_ROOT="$notes_repository_root" \
  zsh "$notes_readiness_script" \
    --app "$notes_app_path" \
    --provenance "$notes_provenance_path" \
    --device-name "$notes_device_name" \
    --device-handoff "$notes_device_handoff_path" \
    > "$notes_readiness_output" 2>&1
notes_readiness_status=$?
set -e
if (( notes_readiness_status != 0 )); then
  fail_readiness "Artifact or iPad readiness failed; install was not attempted"
fi
notes_profile_warning_days="$(
  LC_ALL=C /usr/bin/sed -nE \
    's/^Warning: embedded development profile expires in ([0-9]+) day\(s\)$/\1/p' \
    "$notes_readiness_output" \
    | /usr/bin/sort -u
)"
if [[ "$notes_profile_warning_days" == <-> ]]; then
  print -u2 -- \
    "Warning: embedded development profile expires in $notes_profile_warning_days day(s)"
fi
notes_assert_clean_worktree \
  || fail_readiness "Worktree changed during readiness; install was not attempted"
notes_exact_head_matches_provenance \
  || fail_readiness "Git HEAD changed during readiness; install was not attempted"
cmp -s "$notes_script_path" "$notes_committed_install_script" \
  || fail_readiness "Installer changed during readiness; install was not attempted"
[[ -f "$notes_device_handoff_path" && ! -L "$notes_device_handoff_path" \
  && "$(/usr/bin/stat -f '%Lp' "$notes_device_handoff_path")" == "600" \
  && "$(/usr/bin/stat -f '%z' "$notes_device_handoff_path")" == "36" ]] \
  || fail_readiness "Verified device selector handoff is invalid; install was not attempted"
notes_device_selector="$(<"$notes_device_handoff_path")"
[[ "$notes_device_selector" \
  =~ "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$" ]] \
  || fail_readiness "Verified device selector is invalid; install was not attempted"
unset notes_device_name notes_device_name_lower
print -- "Exact artifact and requested iPad readiness passed"

notes_display_name_contract="$notes_committed_source_dir/internal-display-name-contract.zsh"
if ! notes_repository_git cat-file blob \
  "${notes_provenance_commit}:scripts/internal-display-name-contract.zsh" \
  > "$notes_display_name_contract"
then
  fail_readiness "Display-name contract is missing from the provenance commit; install was not attempted"
fi
chmod 600 "$notes_display_name_contract"
zsh -n "$notes_display_name_contract" \
  || fail_readiness "Display-name contract is invalid; install was not attempted"
source "$notes_display_name_contract"

notes_info_plist="$notes_app_path/Info.plist"
notes_bundle_id="$(
  plutil -extract CFBundleIdentifier raw -o - "$notes_info_plist" 2>/dev/null
)" || fail_readiness "Verified app metadata changed; install was not attempted"
notes_app_version="$(
  plutil -extract CFBundleShortVersionString raw -o - "$notes_info_plist" 2>/dev/null
)" || fail_readiness "Verified app metadata changed; install was not attempted"
notes_app_build="$(
  plutil -extract CFBundleVersion raw -o - "$notes_info_plist" 2>/dev/null
)" || fail_readiness "Verified app metadata changed; install was not attempted"
[[ "$notes_bundle_id" == "com.salomeailin.InkNotes" \
  && "$notes_app_version" == <->.<->.<-> \
  && "$notes_app_build" == <-> ]] \
  || fail_readiness "Verified app identity changed; install was not attempted"
notes_read_internal_display_name \
  "$notes_info_plist" \
  CFBundleDisplayName \
  "$notes_temp_dir" \
  notes_display_name \
  notes_display_name_raw \
  "Installed-app expected display name" \
  || fail_readiness "App display name is invalid; install was not attempted"

notes_install_json="$notes_temp_dir/install-result.json"
notes_install_output="$notes_temp_dir/install-output"
notes_prepare_private_file "$notes_install_json"
notes_prepare_private_file "$notes_install_output"
set +e
/usr/bin/xcrun devicectl device install app \
  --device "$notes_device_selector" \
  --json-output "$notes_install_json" \
  --omit-deprecated-fields-in-json \
  --quiet \
  --timeout 180 \
  "$notes_app_path" \
  > "$notes_install_output" 2>&1
notes_install_status=$?
set -e
if (( notes_install_status != 0 )); then
  fail_install_unknown \
    "Install was attempted but its result is unknown; no retry, removal, or rollback was attempted"
fi
if ! jq -e --arg bundle "$notes_bundle_id" '
  .info.commandType == "devicectl.device.install.app"
  and .info.outcome == "success"
  and .info.jsonVersion == 5
  and (.result.installedApplications | type == "array")
  and (.result.installedApplications | length == 1)
  and .result.installedApplications[0].bundleID == $bundle
  and (.result.installedApplications[0].launchServicesIdentifier | type == "string")
  and (.result.installedApplications[0].launchServicesIdentifier | length > 0)
' "$notes_install_json" >/dev/null 2>&1
then
  fail_install_unknown \
    "Install returned without a valid exact-app result; device state is unknown and no rollback was attempted"
fi
notes_launch_services_identifier="$(
  jq -er '.result.installedApplications[0].launchServicesIdentifier' \
    "$notes_install_json" 2>/dev/null
)" || fail_install_unknown \
  "Install identity could not be retained privately; device state is unknown and no rollback was attempted"

notes_readback_json="$notes_temp_dir/readback-result.json"
notes_readback_output="$notes_temp_dir/readback-output"
notes_prepare_private_file "$notes_readback_json"
notes_prepare_private_file "$notes_readback_output"
set +e
/usr/bin/xcrun devicectl device info apps \
  --device "$notes_device_selector" \
  --bundle-id "$notes_bundle_id" \
  --json-output "$notes_readback_json" \
  --omit-deprecated-fields-in-json \
  --quiet \
  --timeout 60 \
  > "$notes_readback_output" 2>&1
notes_readback_status=$?
set -e
if (( notes_readback_status != 0 )); then
  fail_readback \
    "Install returned success, but device readback failed; the app may be installed, launch was not attempted"
fi
if ! jq -e \
  --arg bundle "$notes_bundle_id" \
  --arg version "$notes_app_version" \
  --arg build "$notes_app_build" \
  --arg name "$notes_display_name" '
    .info.commandType == "devicectl.device.info.apps"
    and .info.outcome == "success"
    and .info.jsonVersion == 5
    and (.result.apps | type == "array")
    and (.result.apps | length == 1)
    and .result.apps[0].bundleIdentifier == $bundle
    and (.result.apps[0].version | type == "string")
    and .result.apps[0].version == $version
    and (.result.apps[0].bundleVersion | type == "string")
    and .result.apps[0].bundleVersion == $build
    and (.result.apps[0].name | type == "string")
    and .result.apps[0].name == $name
  ' "$notes_readback_json" >/dev/null 2>&1
then
  fail_readback \
    "Installed app identity did not match exactly; the app may be installed, launch was not attempted"
fi
print -- "Install readback passed: $notes_bundle_id $notes_app_version ($notes_app_build)"

if [[ "$notes_should_launch" == true ]]; then
  notes_launch_json="$notes_temp_dir/launch-result.json"
  notes_launch_output="$notes_temp_dir/launch-output"
  notes_prepare_private_file "$notes_launch_json"
  notes_prepare_private_file "$notes_launch_output"
  set +e
  /usr/bin/xcrun devicectl device process launch \
    --device "$notes_device_selector" \
    --launch-persistent-identifier "$notes_launch_services_identifier" \
    --json-output "$notes_launch_json" \
    --omit-deprecated-fields-in-json \
    --quiet \
    --timeout 60 \
    "$notes_bundle_id" \
    > "$notes_launch_output" 2>&1
  notes_launch_status=$?
  set -e
  if (( notes_launch_status != 0 )); then
    if /usr/bin/grep -Eiq \
      'The user did not explicitly trust the provisioning profile\.' \
      "$notes_launch_output" "$notes_launch_json" 2>/dev/null
    then
      fail_device_trust \
        "Install is verified, but iPad blocked launch: trust the Developer App in Settings > General > VPN & Device Management, then retry"
    fi
    fail_launch \
      "Install is verified, but launch failed; no existing process was terminated and no raw device error was printed"
  fi
  if ! jq -e '
    .info.commandType == "devicectl.device.process.launch"
    and .info.outcome == "success"
    and .info.jsonVersion == 5
  ' "$notes_launch_json" >/dev/null 2>&1
  then
    fail_launch \
      "Install is verified, but launch result metadata is unsupported; no existing process was terminated"
  fi
  print -- "Launch passed for the exact installed app"
fi

cmp -s "$notes_script_path" "$notes_committed_install_script" \
  || fail_postcondition \
    "Device operation completed, but installer evidence changed; completion is not claimed"
notes_exact_head_matches_provenance \
  || fail_postcondition \
    "Device operation completed, but Git HEAD changed; completion is not claimed"
unset notes_launch_services_identifier
unset notes_device_selector
print -- "iPad install workflow passed without removal or forced process termination"
