#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_checker="$notes_repository_root/scripts/check-baidu-broker-origin.zsh"
notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-baidu-broker-origin-test.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT

fail() {
  print -u2 -- "$1"
  exit 1
}

[[ -x "$notes_checker" && ! -L "$notes_checker" ]] \
  || fail "Baidu broker origin checker is missing or unsafe"

notes_snapshot_paths=(
  "$notes_repository_root/InkNotes/Info.plist"
  "$notes_repository_root/InkNotes.xcodeproj/project.pbxproj"
  "$notes_repository_root/InkNotes/Models/BaiduBrokerProtocolV1.swift"
  "$notes_repository_root/InkNotesCoreTests/BaiduAuthSecurityContractTests.swift"
  "$notes_checker"
)
notes_before="$notes_temp_dir/before.sha256"
notes_after="$notes_temp_dir/after.sha256"
shasum -a 256 "${notes_snapshot_paths[@]}" > "$notes_before"

notes_empty_path="$notes_temp_dir/empty-path"
mkdir -m 700 "$notes_empty_path"
notes_output="$(PATH="$notes_empty_path" "$notes_checker" --origin "https://broker.notes-user-owned.com")"
[[ "$notes_output" == *"本地预检通过"* ]] \
  || fail "Positive broker origin did not pass"
[[ "$notes_output" == *"未联网、未修改工程、未写入配置"* ]] \
  || fail "Read-only and offline boundary was not reported"
[[ "$notes_output" == *"不证明域名所有权、TLS、服务部署或百度授权可用"* ]] \
  || fail "Deployment boundary was not reported"

notes_empty_label=""
notes_long_label="${(l:64::a:)notes_empty_label}"
notes_maximum_label="${(l:63::a:)notes_empty_label}"
notes_long_host="https://$notes_maximum_label.$notes_maximum_label.$notes_maximum_label.$notes_maximum_label.com"
notes_invalid_origins=(
  ""
  "https://"
  "http://broker.notes-user-owned.com"
  "HTTPS://broker.notes-user-owned.com"
  "https://Broker.notes-user-owned.com"
  "https://broker.notes-user-owned.com/"
  "https://broker.notes-user-owned.com/oauth"
  "https://broker.notes-user-owned.com?next=1"
  "https://broker.notes-user-owned.com#callback"
  "https://user@broker.notes-user-owned.com"
  "https://broker.notes-user-owned.com:443"
  "https://broker_notes.notes-user-owned.com"
  "https://-broker.notes-user-owned.com"
  "https://broker-.notes-user-owned.com"
  "https://broker..notes-user-owned.com"
  "https://broker"
  "https://127.0.0.1"
  "https://localhost"
  "https://broker.local"
  "https://broker.test"
  "https://broker.invalid"
  "https://broker.example"
  "https://broker.example.com"
  "https://broker.home.arpa"
  "https://broker.onion"
  "https://xn--broker-9d0b.notes-user-owned.com"
  "https://代理.notes-user-owned.com"
  "https://pan.baidu.com"
  "https://auth.baidu.com"
  "https://broker.baidu.cn"
  "https://broker.baidubce.com"
  "https://$notes_long_label.notes-user-owned.com"
  "$notes_long_host"
  $'https://broker.notes-user-owned.com\n'
)

for notes_invalid_origin in "${notes_invalid_origins[@]}"; do
  if "$notes_checker" --origin "$notes_invalid_origin" >/dev/null 2>&1; then
    fail "Invalid broker origin unexpectedly passed: $notes_invalid_origin"
  fi
done

if "$notes_checker" --unknown "https://broker.notes-user-owned.com" >/dev/null 2>&1; then
  fail "Unknown option unexpectedly passed"
fi
if "$notes_checker" --origin >/dev/null 2>&1; then
  fail "Missing origin unexpectedly passed"
fi

if rg -n '(^|[;&|[:space:]])(curl|wget|nc|ncat|dig|host|nslookup|ping|ssh)([[:space:]]|$)' \
  "$notes_checker" >/dev/null
then
  fail "Broker origin checker contains a network command"
fi

shasum -a 256 "${notes_snapshot_paths[@]}" > "$notes_after"
cmp -s "$notes_before" "$notes_after" \
  || fail "Broker origin preflight changed a protected source file"

print "Baidu broker origin read-only contract tests passed"

exit=0
