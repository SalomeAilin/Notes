#!/bin/zsh
set -euo pipefail

usage() {
  print "Usage: scripts/check-baidu-broker-origin.zsh --origin <https-origin>"
  print ""
  print "Runs a local, read-only broker-origin candidate preflight."
  print "It does not connect to the network or edit the app."
}

fail() {
  print -u2 -- "$1"
  exit 1
}

is_equal_to_or_below() {
  local notes_candidate="$1"
  local notes_suffix="$2"
  [[ "$notes_candidate" == "$notes_suffix" || "$notes_candidate" == *".$notes_suffix" ]]
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 || "$1" != "--origin" ]]; then
  usage >&2
  exit 2
fi

notes_origin="$2"
[[ "$notes_origin" == https://* ]] \
  || fail "候选地址必须使用 HTTPS。"

notes_host="${notes_origin#https://}"
[[ -n "$notes_host" ]] \
  || fail "候选地址缺少域名。"
[[ "$notes_host" =~ '^[a-z0-9.-]+$' ]] \
  || fail "候选地址只能包含小写 ASCII 域名，不能包含账号、端口、路径、参数或视觉混淆字符。"
[[ ${#notes_host} -le 253 ]] \
  || fail "候选域名超过安全长度上限。"
[[ "$notes_host" == *.* && "$notes_host" != .* && "$notes_host" != *. ]] \
  || fail "候选地址必须使用完整域名。"
[[ "$notes_host" != *..* ]] \
  || fail "候选域名包含空标签。"

notes_labels=("${(@s:.:)notes_host}")
for notes_label in "${notes_labels[@]}"; do
  [[ ${#notes_label} -le 63 ]] \
    || fail "候选域名标签超过安全长度上限。"
  [[ "$notes_label" =~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' ]] \
    || fail "候选域名标签格式无效。"
  [[ "$notes_label" != xn--* ]] \
    || fail "候选域名不能使用容易产生视觉混淆的编码标签。"
done

notes_top_level_label="${notes_labels[-1]}"
[[ "$notes_top_level_label" =~ '^[a-z]{2,63}$' ]] \
  || fail "候选地址必须使用规范的字母顶级域名。"

notes_reserved_suffixes=(
  localhost
  local
  test
  invalid
  example
  example.com
  example.net
  example.org
  home.arpa
  onion
)
for notes_suffix in "${notes_reserved_suffixes[@]}"; do
  if is_equal_to_or_below "$notes_host" "$notes_suffix"; then
    fail "候选地址不能使用本机、保留或示例域名。"
  fi
done

notes_baidu_suffixes=(
  baidu.com
  baidu.cn
  baidubce.com
  baidu-int.com
)
for notes_suffix in "${notes_baidu_suffixes[@]}"; do
  if is_equal_to_or_below "$notes_host" "$notes_suffix"; then
    fail "自有 broker 不能使用或冒充百度官方域名。"
  fi
done

print -r -- "本地预检通过：候选地址 $notes_origin"
print -r -- "未联网、未修改工程、未写入配置，也未注册回调或授权入口。"
print -r -- "本结果只说明地址满足当前最小格式边界，不证明域名所有权、TLS、服务部署或百度授权可用。"
print -r -- "正式接入前仍需验证域名控制权、证书、响应身份、回调、单次票据、撤销流程和真实账号。"

exit=0
