#!/bin/zsh
set -euo pipefail
umask 077
notes_root="${0:A:h:h}"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-connection-test.XXXXXX")"
trap 'rm -rf "$notes_temp_dir"' EXIT
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_selector="11111111-2222-3333-4444-555555555555"

# Exercise the shipped function with a private transport stub, never a device.
awk '/^notes_verify_live_ipad\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' \
  "$notes_root/scripts/verify-ipad-readiness.sh" \
  | sed 's@/usr/bin/xcrun@notes_fake_xcrun@g' > "$notes_temp_dir/probe.zsh"
source "$notes_temp_dir/probe.zsh"
notes_calls=0
notes_case="success"
notes_fake_xcrun() {
  (( notes_calls += 1 ))
  [[ "$*" == "devicectl device info apps --device $notes_selector --bundle-id $notes_expected_bundle_id --json-output $notes_temp_dir/live-device-probe.json --omit-deprecated-fields-in-json --quiet --timeout 30" ]] || return 1
  case "$notes_case" in
    transport-failure) return 1 ;;
    invalid-json) print 'invalid' > "$notes_temp_dir/live-device-probe.json"; return 0 ;;
  esac
  local notes_outcome=success notes_version=5 notes_type=devicectl.device.info.apps
  local notes_apps='[{"bundleIdentifier":"com.salomeailin.InkNotes"}]'
  case "$notes_case" in
    empty) notes_apps='[]' ;;
    wrong-app) notes_apps='[{"bundleIdentifier":"other.app"}]' ;;
    duplicate) notes_apps='[{"bundleIdentifier":"com.salomeailin.InkNotes"},{"bundleIdentifier":"com.salomeailin.InkNotes"}]' ;;
    invalid-apps) notes_apps='null' ;;
    outcome-failure) notes_outcome=failure ;;
    wrong-version) notes_version=4 ;;
    wrong-command) notes_type=devicectl.list.devices ;;
  esac
  jq -n --arg outcome "$notes_outcome" --arg type "$notes_type" \
    --argjson version "$notes_version" --argjson apps "$notes_apps" \
    '{info:{outcome:$outcome,commandType:$type,jsonVersion:$version},result:{apps:$apps}}' \
    > "$notes_temp_dir/live-device-probe.json"
}

for notes_state in connected disconnected; do
  for notes_case in success empty; do
    notes_verify_live_ipad "$notes_state" "$notes_selector" \
      || { print -u2 "Live reachable device was rejected"; exit 1; }
  done
  for notes_case in transport-failure invalid-json wrong-app duplicate invalid-apps outcome-failure wrong-version wrong-command; do
    if notes_verify_live_ipad "$notes_state" "$notes_selector"; then
      print -u2 "Invalid live response was accepted: $notes_case"
      exit 1
    fi
  done
done
notes_case=success
for notes_state in unavailable unknown ''; do
  notes_before=$notes_calls
  if notes_verify_live_ipad "$notes_state" "$notes_selector"; then
    print -u2 "Unavailable or unknown state was accepted"
    exit 1
  fi
  [[ "$notes_calls" == "$notes_before" ]] || exit 1
done
print 'iPad live connection contract tests passed'
