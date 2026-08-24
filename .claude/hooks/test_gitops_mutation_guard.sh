#!/usr/bin/env bash
# Real, runnable test for the PreToolUse GitOps mutation guard
# (gitops-mutation-guard.py). Feeds the hook synthetic PreToolUse JSON on
# stdin exactly as Claude Code would, and asserts on its stdout/exit code.
#
# Usage: ./test_gitops_mutation_guard.sh
# Exits 0 if all cases pass, 1 if any fail.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/gitops-mutation-guard.py"

pass_count=0
fail_count=0

# make_input <bash-command>
make_input() {
  local cmd="$1"
  python3 -c '
import json, sys
print(json.dumps({
    "session_id": "test",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1]},
}))
' "$cmd"
}

# assert_blocked <name> <bash-command> [env_var=value ...]
assert_blocked() {
  local name="$1" cmd="$2"
  local output
  output=$(make_input "$cmd" | "$HOOK")
  if echo "$output" | grep -q '"permissionDecision": *"deny"'; then
    echo "PASS: $name (blocked as expected)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name -- expected deny, got: ${output:-<no output, i.e. allowed>}"
    fail_count=$((fail_count + 1))
  fi
}

# assert_allowed <name> <bash-command>
assert_allowed() {
  local name="$1" cmd="$2"
  local output
  output=$(make_input "$cmd" | "$HOOK")
  if echo "$output" | grep -q '"permissionDecision": *"deny"'; then
    echo "FAIL: $name -- expected allow, got deny: $output"
    fail_count=$((fail_count + 1))
  else
    echo "PASS: $name (allowed as expected)"
    pass_count=$((pass_count + 1))
  fi
}

TOKEN="ADAMASTORX_CONFIRM_MUTATION=1"

echo "== (a) mutating commands with NO token -> must be blocked =="
assert_blocked "kubectl apply, no token"            "kubectl apply -f manifest.yaml"
assert_blocked "kubectl delete, no token"           "kubectl delete pod stuck-pod -n api"
assert_blocked "kubectl patch, no token"            "kubectl patch deployment api -p '{\"spec\":{}}'"
assert_blocked "kubectl scale, no token"            "kubectl scale deployment/api --replicas=3"
assert_blocked "terraform apply, no token"          "terraform apply"
assert_blocked "terraform destroy, no token"        "cd platform/terraform && terraform destroy -auto-approve"
assert_blocked "chained mutation, no token"         "kubectl get pods && kubectl delete pod foo"

echo
echo "== (b) the SAME mutating commands WITH the token -> must be allowed =="
assert_allowed "kubectl apply, with token"          "$TOKEN kubectl apply -f manifest.yaml"
assert_allowed "kubectl delete, with token"         "$TOKEN kubectl delete pod stuck-pod -n api"
assert_allowed "kubectl patch, with token"          "$TOKEN kubectl patch deployment api -p '{\"spec\":{}}'"
assert_allowed "kubectl scale, with token"          "$TOKEN kubectl scale deployment/api --replicas=3"
assert_allowed "terraform apply, with token"        "$TOKEN terraform apply"
assert_allowed "terraform destroy, with token"      "cd platform/terraform && $TOKEN terraform destroy -auto-approve"

echo
echo "== (c) read-only commands -> must NEVER be blocked, token or not =="
READONLY_CMDS=(
  "kubectl get pods -n api"
  "kubectl describe deployment api -n api"
  "kubectl logs -f deploy/api -n api"
  "kubectl top nodes"
  "kubectl explain pod.spec"
  "kubectl diff -f manifest.yaml"
  "terraform plan"
  "terraform validate"
  "terraform show"
  "terraform output"
  "kubectl apply -f manifest.yaml --dry-run=client"
)
for cmd in "${READONLY_CMDS[@]}"; do
  assert_allowed "readonly, no token: $cmd" "$cmd"
  assert_allowed "readonly, WITH token (must still allow): $cmd" "$TOKEN $cmd"
done

echo
echo "== (d) non-Bash tool calls and unrelated Bash commands -> never blocked =="
non_bash_input='{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}'
output=$(echo "$non_bash_input" | "$HOOK")
if echo "$output" | grep -q '"permissionDecision": *"deny"'; then
  echo "FAIL: non-Bash tool call -- expected allow, got deny: $output"
  fail_count=$((fail_count + 1))
else
  echo "PASS: non-Bash tool call (allowed as expected)"
  pass_count=$((pass_count + 1))
fi
assert_allowed "unrelated command" "ls -la /tmp"
assert_allowed "git command" "git status"

echo
echo "=================================================="
echo "Results: $pass_count passed, $fail_count failed"
echo "=================================================="

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
