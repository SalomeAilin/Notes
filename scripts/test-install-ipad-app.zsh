#!/bin/zsh
set -euo pipefail

notes_source_root="${0:A:h:h}"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-installer-test.XXXXXX")"
chmod 700 "$notes_temp_dir"
notes_temp_dir="$(cd "$notes_temp_dir" && pwd -P)"
trap 'rm -rf "$notes_temp_dir"' EXIT

notes_fixture_root="$notes_temp_dir/repository"
notes_fixture_scripts="$notes_fixture_root/scripts"
notes_fake_bin="$notes_temp_dir/fake-bin"
notes_fake_developer_dir="$notes_temp_dir/fake-developer"
notes_runtime_temp="$notes_temp_dir/runtime"
notes_git_home="$notes_temp_dir/git-home"
notes_git_xdg="$notes_temp_dir/git-xdg"
notes_git_temp="$notes_temp_dir/git-tmp"
notes_app_path="$notes_temp_dir/Fixture.app"
notes_provenance_path="$notes_temp_dir/provenance.json"
notes_trace_path="$notes_temp_dir/trace"
mkdir -p -m 700 \
  "$notes_fixture_scripts" \
  "$notes_fake_bin" \
  "$notes_fake_developer_dir" \
  "$notes_runtime_temp" \
  "$notes_git_home" \
  "$notes_git_xdg" \
  "$notes_git_temp" \
  "$notes_app_path"

notes_fixture_git() {
  /usr/bin/env -i \
    HOME="$notes_git_home" \
    XDG_CONFIG_HOME="$notes_git_xdg" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="$notes_git_temp" \
    LC_ALL=C \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects -C "$notes_fixture_root" "$@"
}

cp "$notes_source_root/scripts/install-ipad-app.sh" \
  "$notes_fixture_scripts/install-ipad-app.sh"
cp "$notes_source_root/scripts/internal-display-name-contract.zsh" \
  "$notes_fixture_scripts/internal-display-name-contract.zsh"
cp "$notes_source_root/scripts/test-fixtures/ipad-installer/verify-ipad-readiness.sh" \
  "$notes_fixture_scripts/verify-ipad-readiness.sh"
cp "$notes_source_root/scripts/test-fixtures/ipad-installer/xcrun" \
  "$notes_fake_bin/xcrun"
INKNOTES_FIXTURE_XCRUN="$notes_fake_bin/xcrun" /usr/bin/perl -pi -e '
  BEGIN { $replacement = $ENV{"INKNOTES_FIXTURE_XCRUN"}; }
  s{\Q/usr/bin/xcrun\E}{$replacement}g;
' "$notes_fixture_scripts/install-ipad-app.sh"
chmod 755 \
  "$notes_fixture_scripts/install-ipad-app.sh" \
  "$notes_fixture_scripts/verify-ipad-readiness.sh" \
  "$notes_fake_bin/xcrun"
chmod 644 "$notes_fixture_scripts/internal-display-name-contract.zsh"

notes_fixture_git init -q
notes_fixture_git \
  -c core.hooksPath=/dev/null \
  -c user.name=Compatibility \
  -c user.email=compatibility@example.invalid \
  -c commit.gpgsign=false \
  add scripts
notes_fixture_git \
  -c core.hooksPath=/dev/null \
  -c user.name=Compatibility \
  -c user.email=compatibility@example.invalid \
  -c commit.gpgsign=false \
  commit -q -m "fixture"
notes_fixture_commit="$(notes_fixture_git rev-parse HEAD)"
print -r -- "head switch fixture" > "$notes_fixture_root/head-switch-marker"
notes_fixture_git \
  -c core.hooksPath=/dev/null \
  -c user.name=Compatibility \
  -c user.email=compatibility@example.invalid \
  -c commit.gpgsign=false \
  add head-switch-marker
notes_fixture_git \
  -c core.hooksPath=/dev/null \
  -c user.name=Compatibility \
  -c user.email=compatibility@example.invalid \
  -c commit.gpgsign=false \
  commit -q -m "alternate clean head"
notes_alternate_commit="$(notes_fixture_git rev-parse HEAD)"
notes_fixture_git checkout -q "$notes_fixture_commit"

notes_source_plist="$notes_source_root/InkNotes/Info.plist"
notes_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$notes_source_plist")"
notes_bundle_id="$(
  rg -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;' \
    "$notes_source_root/InkNotes.xcodeproj/project.pbxproj" \
    | sed -E 's/.* = ([^;]+);/\1/' \
    | sort -u
)"
notes_app_version="$(
  rg -o 'MARKETING_VERSION = [^;]+;' "$notes_source_root/InkNotes.xcodeproj/project.pbxproj" \
    | sed -E 's/.* = ([^;]+);/\1/' \
    | sort -u
)"
notes_app_build="$(
  rg -o 'CURRENT_PROJECT_VERSION = [0-9]+;' \
    "$notes_source_root/InkNotes.xcodeproj/project.pbxproj" \
    | sed -E 's/.* = ([0-9]+);/\1/' \
    | sort -u
)"
[[ "$notes_app_version" == <->.<->.<-> ]]
[[ "$notes_app_build" == <-> ]]
[[ "$notes_bundle_id" =~ "^[[:alnum:].-]+$" ]]

plutil -create xml1 "$notes_app_path/Info.plist"
plutil -insert CFBundleIdentifier -string "$notes_bundle_id" "$notes_app_path/Info.plist"
plutil -insert CFBundleDisplayName -string "$notes_display_name" "$notes_app_path/Info.plist"
plutil -insert CFBundleShortVersionString -string "$notes_app_version" \
  "$notes_app_path/Info.plist"
plutil -insert CFBundleVersion -string "$notes_app_build" "$notes_app_path/Info.plist"

plutil -create xml1 "$notes_provenance_path"
plutil -insert schemaVersion -integer 2 "$notes_provenance_path"
plutil -insert gitCommit -string "$notes_fixture_commit" "$notes_provenance_path"
plutil -insert displayName -string "$notes_display_name" "$notes_provenance_path"
chmod 600 "$notes_provenance_path"

notes_installer="$notes_fixture_scripts/install-ipad-app.sh"
notes_device_name="Fixture_iPad"
notes_device_selector="11111111-2222-3333-4444-555555555555"
notes_sensitive_sentinel="SENSITIVE-UDID-00000000-PRIVATE-PATH"

notes_fail() {
  print -u2 -- "$1"
  exit 1
}

notes_assert_output_is_redacted() {
  local notes_output_path="$1"
  if /usr/bin/grep -Fq "$notes_sensitive_sentinel" "$notes_output_path"; then
    notes_fail "Installer exposed captured CoreDevice output"
  fi
  if /usr/bin/grep -Fq "$notes_app_path" "$notes_output_path"; then
    notes_fail "Installer exposed the local app path"
  fi
  if /usr/bin/grep -Fq "$notes_provenance_path" "$notes_output_path"; then
    notes_fail "Installer exposed the local provenance path"
  fi
  if /usr/bin/grep -Fq "$notes_device_name" "$notes_output_path"; then
    notes_fail "Installer exposed the exact device name"
  fi
  if /usr/bin/grep -Fq "$notes_device_selector" "$notes_output_path"; then
    notes_fail "Installer exposed the private CoreDevice selector"
  fi
}

notes_run_scenario() {
  local notes_label="$1"
  local notes_expected_status="$2"
  local notes_expected_trace="$3"
  local notes_readiness_status="$4"
  local notes_install_mode="$5"
  local notes_readback_mode="$6"
  local notes_launch_mode="$7"
  local notes_launch_requested="$8"
  local notes_checkout_commit="${9:-}"
  local notes_output_path="$notes_temp_dir/output-$notes_label"
  local -a notes_arguments=(
    --app "$notes_app_path"
    --provenance "$notes_provenance_path"
    --device-name "$notes_device_name"
  )
  if [[ "$notes_launch_requested" == true ]]; then
    notes_arguments+=(--launch)
  fi

  : > "$notes_trace_path"
  : > "$notes_output_path"
  chmod 600 "$notes_trace_path" "$notes_output_path"
  set +e
  /usr/bin/env \
    DEVELOPER_DIR="$notes_fake_developer_dir" \
    PATH="$notes_fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$notes_runtime_temp" \
    INKNOTES_FAKE_TRACE="$notes_trace_path" \
    INKNOTES_FAKE_APP="$notes_app_path" \
    INKNOTES_FAKE_PROVENANCE="$notes_provenance_path" \
    INKNOTES_FAKE_DEVICE="$notes_device_name" \
    INKNOTES_FAKE_SELECTOR="$notes_device_selector" \
    INKNOTES_FAKE_BUNDLE="$notes_bundle_id" \
    INKNOTES_FAKE_VERSION="$notes_app_version" \
    INKNOTES_FAKE_BUILD="$notes_app_build" \
    INKNOTES_FAKE_NAME="$notes_display_name" \
    INKNOTES_FAKE_SENSITIVE_SENTINEL="$notes_sensitive_sentinel" \
    INKNOTES_FAKE_READINESS_STATUS="$notes_readiness_status" \
    INKNOTES_FAKE_PROFILE_DAYS=6 \
    INKNOTES_FAKE_REPOSITORY="$notes_fixture_root" \
    INKNOTES_FAKE_CHECKOUT_COMMIT="$notes_checkout_commit" \
    INKNOTES_FAKE_INSTALL_MODE="$notes_install_mode" \
    INKNOTES_FAKE_READBACK_MODE="$notes_readback_mode" \
    INKNOTES_FAKE_LAUNCH_MODE="$notes_launch_mode" \
    "$notes_installer" "${notes_arguments[@]}" \
    > "$notes_output_path" 2>&1
  local notes_actual_status=$?
  set -e
  notes_fixture_git checkout -q "$notes_fixture_commit"

  notes_assert_output_is_redacted "$notes_output_path"
  if [[ "$notes_actual_status" != "$notes_expected_status" ]]; then
    print -u2 -- "$notes_label returned $notes_actual_status instead of $notes_expected_status"
    sed -n '1,40p' "$notes_output_path" >&2
    exit 1
  fi
  local notes_actual_trace="$(<"$notes_trace_path")"
  [[ "$notes_actual_trace" == "$notes_expected_trace" ]] \
    || notes_fail "$notes_label used an unexpected device-operation sequence"
  local -a notes_leftovers=("$notes_runtime_temp"/inknotes-install.*(N))
  (( ${#notes_leftovers} == 0 )) \
    || notes_fail "$notes_label retained private installer artifacts"
}

: > "$notes_trace_path"
chmod 600 "$notes_trace_path"
notes_help_output="$notes_temp_dir/output-help"
/usr/bin/env \
  DEVELOPER_DIR="$notes_fake_developer_dir" \
  PATH="$notes_fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  INKNOTES_FAKE_TRACE="$notes_trace_path" \
  "$notes_installer" --help > "$notes_help_output" 2>&1
[[ ! -s "$notes_trace_path" ]] || notes_fail "--help touched the device command boundary"

notes_unknown_output="$notes_temp_dir/output-unknown"
set +e
/usr/bin/env \
  DEVELOPER_DIR="$notes_fake_developer_dir" \
  PATH="$notes_fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  INKNOTES_FAKE_TRACE="$notes_trace_path" \
  "$notes_installer" --unknown > "$notes_unknown_output" 2>&1
notes_unknown_status=$?
set -e
[[ "$notes_unknown_status" == 2 ]] || notes_fail "Unknown option did not fail as usage error"
[[ ! -s "$notes_trace_path" ]] || notes_fail "Unknown option touched the device command boundary"

notes_reserved_output="$notes_temp_dir/output-reserved-device-name"
set +e
/usr/bin/env \
  DEVELOPER_DIR="$notes_fake_developer_dir" \
  PATH="$notes_fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  INKNOTES_FAKE_TRACE="$notes_trace_path" \
  "$notes_installer" \
    --app "$notes_app_path" \
    --provenance "$notes_provenance_path" \
    --device-name "The user did not explicitly trust the provisioning profile" \
    > "$notes_reserved_output" 2>&1
notes_reserved_status=$?
set -e
[[ "$notes_reserved_status" == 2 ]] \
  || notes_fail "Reserved diagnostic device name did not fail as a usage error"
[[ ! -s "$notes_trace_path" ]] \
  || notes_fail "Reserved diagnostic device name touched the device command boundary"

notes_run_scenario \
  readiness-failure 3 "readiness" 9 success success success false
notes_run_scenario \
  readiness-head-switch 3 "readiness" 0 success success success false \
  "$notes_alternate_commit"
notes_run_scenario \
  install-only 0 $'readiness\ninstall\ninfo' 0 success success success false
notes_run_scenario \
  launch-success 0 $'readiness\ninstall\ninfo\nlaunch' 0 success success success true
notes_run_scenario \
  install-nonzero 4 $'readiness\ninstall' 0 nonzero success success true
notes_run_scenario \
  install-malformed 4 $'readiness\ninstall' 0 malformed success success true
notes_run_scenario \
  install-wrong-command 4 $'readiness\ninstall' 0 wrong-command success success true
notes_run_scenario \
  readback-zero 5 $'readiness\ninstall\ninfo' 0 success zero success true
notes_run_scenario \
  readback-two 5 $'readiness\ninstall\ninfo' 0 success two success true
notes_run_scenario \
  readback-wrong-version 5 $'readiness\ninstall\ninfo' 0 success wrong-version success true
notes_run_scenario \
  readback-malformed 5 $'readiness\ninstall\ninfo' 0 success malformed success true
notes_run_scenario \
  launch-trust 7 $'readiness\ninstall\ninfo\nlaunch' 0 success success trust true
notes_run_scenario \
  launch-generic 6 $'readiness\ninstall\ninfo\nlaunch' 0 success success generic-trust-word true
notes_run_scenario \
  launch-ambiguous 6 $'readiness\ninstall\ninfo\nlaunch' 0 success success ambiguous-signature true

notes_trust_output="$notes_temp_dir/output-launch-trust"
/usr/bin/grep -Fq \
  "Settings > General > VPN & Device Management" \
  "$notes_trust_output" \
  || notes_fail "Developer App trust failure did not produce fixed guidance"
notes_generic_output="$notes_temp_dir/output-launch-generic"
if /usr/bin/grep -Fq \
  "Settings > General > VPN & Device Management" \
  "$notes_generic_output"
then
  notes_fail "Generic trust wording was misclassified as Developer App trust"
fi
notes_ambiguous_output="$notes_temp_dir/output-launch-ambiguous"
if /usr/bin/grep -Fq \
  "Settings > General > VPN & Device Management" \
  "$notes_ambiguous_output"
then
  notes_fail "Ambiguous signature failure was misclassified as Developer App trust"
fi
notes_install_output="$notes_temp_dir/output-install-only"
/usr/bin/grep -Fq \
  "Warning: embedded development profile expires in 6 day(s)" \
  "$notes_install_output" \
  || notes_fail "Sanitized provisioning-profile warning was not relayed"

notes_source_display_name="$notes_display_name"
notes_display_name="候选名称"
plutil -replace CFBundleDisplayName -string "$notes_display_name" "$notes_app_path/Info.plist"
plutil -replace schemaVersion -integer 3 "$notes_provenance_path"
plutil -replace displayName -string "$notes_display_name" "$notes_provenance_path"
plutil -insert brandPreview -bool true "$notes_provenance_path"
plutil -insert sourceDisplayName -string "$notes_source_display_name" "$notes_provenance_path"
notes_run_scenario \
  brand-preview-install 0 $'readiness\ninstall\ninfo' 0 success success success false

print -- "iPad installer offline contract tests passed"
