#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_checker="$notes_repository_root/scripts/check-brand-candidate.zsh"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-brand-candidate-test.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT

fail() {
  print -u2 -- "$1"
  exit 1
}

[[ -x "$notes_checker" && ! -L "$notes_checker" ]] \
  || fail "Brand candidate checker is missing or unsafe"

notes_snapshot_paths=(
  "$notes_repository_root/InkNotes/Info.plist"
  "$notes_repository_root/InkNotes.xcodeproj/project.pbxproj"
  "$notes_repository_root/InkNotes/Persistence/BackupArchiveCodec.swift"
  "$notes_repository_root/scripts/internal-display-name-contract.zsh"
)
notes_before="$notes_temp_dir/before.sha256"
notes_after="$notes_temp_dir/after.sha256"
shasum -a 256 "${notes_snapshot_paths[@]}" > "$notes_before"

notes_output="$($notes_checker --name "候选名称")"
[[ "$notes_output" == *"本地预检通过"* ]] \
  || fail "Positive candidate did not pass"
[[ "$notes_output" == *"未修改工程文件、应用身份或备份身份"* ]] \
  || fail "Read-only boundary was not reported"
[[ "$notes_output" == *"不是商标、App Store 或公开市场可用性结论"* ]] \
  || fail "Legal and marketplace boundary was not reported"

notes_current_display_name="$(
  plutil -extract CFBundleDisplayName raw -o - "$notes_repository_root/InkNotes/Info.plist"
)"
notes_invalid_names=(
  ""
  "   "
  " 候选名称"
  "候选名称 "
  $'候选\n名称'
  $'候选\t名称'
  $'候选\u200B名称'
  "!!!"
  "$(printf '候选%.0s' {1..16})"
  '$('
  '${'
  '$(PRODUCT_NAME)'
  'prefix墨记suffix'
  'prefix墨記suffix'
  'prefix墨计suffix'
  'prefix墨計suffix'
  "$notes_current_display_name"
)

for notes_invalid_name in "${notes_invalid_names[@]}"; do
  if "$notes_checker" --name "$notes_invalid_name" >/dev/null 2>&1; then
    fail "Invalid candidate unexpectedly passed"
  fi
done

if "$notes_checker" --unknown "候选名称" >/dev/null 2>&1; then
  fail "Unknown option unexpectedly passed"
fi
if "$notes_checker" --name >/dev/null 2>&1; then
  fail "Missing candidate unexpectedly passed"
fi

shasum -a 256 "${notes_snapshot_paths[@]}" > "$notes_after"
cmp -s "$notes_before" "$notes_after" \
  || fail "Brand candidate preflight changed a protected source file"

print "Brand candidate read-only contract tests passed"
