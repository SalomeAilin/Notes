#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_contract_path="$notes_repository_root/scripts/internal-display-name-contract.zsh"
notes_source_plist="$notes_repository_root/InkNotes/Info.plist"
notes_expected_bundle_id="com.salomeailin.InkNotes"

usage() {
  print "Usage: scripts/check-brand-candidate.zsh --name <candidate>"
  print ""
  print "Runs a local, read-only candidate-name preflight. It does not edit the app."
}

fail() {
  print -u2 -- "$1"
  exit 1
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 || "$1" != "--name" ]]; then
  usage >&2
  exit 2
fi

notes_candidate="$2"
[[ -f "$notes_contract_path" && ! -L "$notes_contract_path" ]] \
  || fail "显示名检查规则缺失或不安全。"
[[ -f "$notes_source_plist" && ! -L "$notes_source_plist" ]] \
  || fail "应用显示名配置缺失或不安全。"

source "$notes_contract_path"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-brand-candidate.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT

notes_candidate_path="$notes_temp_dir/candidate.raw"
print -rn -- "$notes_candidate" > "$notes_candidate_path"
chmod 600 "$notes_candidate_path"
notes_validate_internal_display_name_file \
  "$notes_candidate_path" \
  "候选名称" \
  || fail "候选名称未通过本地字符与退役名称检查。"

notes_current_display_name=""
notes_current_display_name_raw=""
notes_read_internal_placeholder_display_name \
  "$notes_source_plist" \
  CFBundleDisplayName \
  "$notes_temp_dir" \
  notes_current_display_name \
  notes_current_display_name_raw \
  "当前开发包显示名" \
  "$notes_expected_bundle_id" \
  || fail "当前工程不再处于受保护的内部占位状态，未继续检查。"

if [[ "$notes_candidate" == "$notes_current_display_name" ]]; then
  fail "候选名称不能仍是当前内部占位名。"
fi

print -r -- "本地预检通过：候选名称“$notes_candidate”"
print -r -- "未修改工程文件、应用身份或备份身份。"
print -r -- "这不是商标、App Store 或公开市场可用性结论。"
print -r -- "下一步仍需由用户确认候选，并完成相关商标类别与公开市场核查。"
