#!/usr/bin/env bash
# Real, runnable test for the SessionStart convenience hook
# (session-start-brief.py). Feeds the hook synthetic SessionStart JSON on
# stdin exactly as Claude Code would, and asserts on its stdout.
#
# This only proves the hook script itself behaves correctly when invoked
# the way Claude Code's runtime invokes hooks. It cannot prove a real
# SessionStart event fires this script inside an actual Claude Code
# session, or that a later Bash tool call in that session really sees
# KUBECONFIG (that part is set by ../settings.json's `env` block, not by
# this script -- see this hook's own docstring). See the PR description
# for what was and wasn't independently verified end-to-end.
#
# Usage: ./test_session_start_brief.sh
# Exits 0 if all cases pass, 1 if any fail.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/session-start-brief.py"

pass_count=0
fail_count=0

# make_input <source>
make_input() {
  local source="$1"
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "test",
    "transcript_path": "/tmp/fake-transcript.jsonl",
    "cwd": "/home/lmpeixoto/repos/AdamastorX/platform",
    "hook_event_name": "SessionStart",
    "source": sys.argv[1],
}))
' "$source"
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name -- expected to find: $needle"
    fail_count=$((fail_count + 1))
  fi
}

echo "== (a) valid SessionStart payload (source=startup) =="
output=$(make_input "startup" | "$HOOK")
assert_contains "exits with parseable JSON"            "$(echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>&1)" "ok"
assert_contains "hookEventName is SessionStart"         "$output" '"hookEventName": "SessionStart"'
assert_contains "mentions KUBECONFIG path"              "$output" "/home/lmpeixoto/repos/AdamastorX/platform/terraform/kubeconfig"
assert_contains "mentions the env block, not the hook, sets it" "$output" "not by this hook"
assert_contains "mentions backlog #150"                 "$output" "backlog #150"
assert_contains "includes ArgoCD root-refresh gremlin"  "$output" "root"
assert_contains "includes Boot 4.1 autoconfig gremlin"  "$output" "Boot 4.1"
assert_contains "includes Cilium DNS proxy gremlin"     "$output" "Cilium's DNS proxy"

echo
echo "== (b) other SessionStart sources (resume/clear/compact/fork) still produce a brief =="
for source in resume clear compact fork; do
  output=$(make_input "$source" | "$HOOK")
  assert_contains "source=$source still mentions gremlins" "$output" "Known gremlins"
done

echo
echo "== (c) malformed stdin -- must fail open, not crash or hang =="
output=$(echo "not valid json" | "$HOOK")
assert_contains "malformed stdin still returns a brief" "$output" "hookEventName"

echo
echo "== (d) exit code is always 0 (SessionStart hooks should never block startup) =="
echo "not valid json" | "$HOOK" > /dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: exit code 0 on malformed input"
  pass_count=$((pass_count + 1))
else
  echo "FAIL: exit code $rc on malformed input -- expected 0"
  fail_count=$((fail_count + 1))
fi

echo
echo "=================================================="
echo "Results: $pass_count passed, $fail_count failed"
echo "=================================================="

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
