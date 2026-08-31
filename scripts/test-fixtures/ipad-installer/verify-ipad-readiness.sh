#!/bin/zsh
set -euo pipefail

notes_trace_path="${INKNOTES_FAKE_TRACE:?}"
notes_expected_app="${INKNOTES_FAKE_APP:?}"
notes_expected_provenance="${INKNOTES_FAKE_PROVENANCE:?}"
notes_expected_device="${INKNOTES_FAKE_DEVICE:?}"
notes_expected_selector="${INKNOTES_FAKE_SELECTOR:?}"
notes_status="${INKNOTES_FAKE_READINESS_STATUS:-0}"
notes_profile_days="${INKNOTES_FAKE_PROFILE_DAYS:-}"
notes_checkout_commit="${INKNOTES_FAKE_CHECKOUT_COMMIT:-}"
notes_repository_path="${INKNOTES_FAKE_REPOSITORY:-}"

print -- "readiness" >> "$notes_trace_path"

[[ "$#" == 8 ]]
[[ "$1" == "--app" && "$2" == "$notes_expected_app" ]]
[[ "$3" == "--provenance" && "$4" == "$notes_expected_provenance" ]]
[[ "$5" == "--device-name" && "$6" == "$notes_expected_device" ]]
[[ "$7" == "--device-handoff" ]]
notes_handoff_path="$8"
[[ -f "$notes_handoff_path" && ! -L "$notes_handoff_path" && ! -s "$notes_handoff_path" ]]
[[ "$(/usr/bin/stat -f '%Lp' "$notes_handoff_path")" == "600" ]]
[[ "$(/usr/bin/stat -f '%Lp' "${notes_handoff_path:h}")" == "700" ]]

if [[ "$notes_status" != 0 ]]; then
  print -u2 -- "fixture readiness rejected the request"
  exit "$notes_status"
fi

print -rn -- "$notes_expected_selector" > "$notes_handoff_path"
[[ "$(/usr/bin/stat -f '%z' "$notes_handoff_path")" == "36" ]]
if [[ "$notes_profile_days" == <-> ]]; then
  print -u2 -- "Warning: embedded development profile expires in $notes_profile_days day(s)"
fi
if [[ -n "$notes_checkout_commit" ]]; then
  [[ -n "$notes_repository_path" ]]
  /usr/bin/git -C "$notes_repository_path" checkout -q "$notes_checkout_commit"
fi

print -- "fixture readiness passed"
