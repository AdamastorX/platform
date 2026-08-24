#!/usr/bin/env python3
"""ADAMASTORX SessionStart hook: convenience brief, not enforcement.

Backlog #150. Wired as a SessionStart hook (no matcher restriction, so it
fires on every startup/resume/clear/compact/fork) in ../settings.json.
Distinct from backlog #149's PreToolUse `gitops-mutation-guard.py`: that
hook mechanically *blocks* mutating kubectl/terraform commands; this one
makes no decision and blocks nothing -- it only surfaces information a
session would otherwise have to go rediscover by hand.

What this hook actually does, and what it deliberately does NOT do
--------------------------------------------------------------------
This hook does exactly one thing: it prints `known-gremlins.md` (a short,
hand-maintained excerpt of `adamastorx/docs/SESSION_STATE.md`'s current
gremlin log) into the new session's context via `additionalContext`, so
the gremlin list is *read* at session start instead of *rediscovered* the
hard way. That part works as advertised -- SessionStart hook stdout/JSON
is documented to be added to the transcript as context Claude can see and
act on.

KUBECONFIG is intentionally handled *elsewhere*, not by this script:
------------------------------------------------------------------
The backlog item's acceptance criteria frames this as a "SessionStart
hook that exports KUBECONFIG." That framing doesn't survive contact with
how SessionStart hooks actually work: a hook is a short-lived subprocess.
Anything it `export`s, or prints as plain shell syntax, dies with that
subprocess -- there is no supported mechanism for a SessionStart hook's
own output to mutate the environment of Claude Code's own process or of
later Bash tool invocations. Printing `export KUBECONFIG=...` here would
look like it works (it would even echo convincingly in the transcript)
while doing nothing for the very next `Bash` tool call.

The real, working mechanism for "every session's Bash calls see
KUBECONFIG set, no manual export" is the top-level `env` block in
`../settings.json` -- documented as setting environment variables "for
every session and its subprocesses," which includes the Bash tool. That's
where KUBECONFIG is actually set for this repo now; this script does not
touch it. (Confirmed via the current hooks/settings/permissions docs at
https://code.claude.com/docs/en/hooks,
https://code.claude.com/docs/en/settings-reference, and
https://code.claude.com/docs/en/permissions -- the last of these confirms
`env` block values apply even when only a *parent* folder has been
trusted, same tier as hooks, unlike `permissions.allow` rules.)

This script still mentions the KUBECONFIG path in its printed brief, as a
visible confirmation of where it's coming from -- not because this script
is the thing setting it.
"""
import json
import os
import sys

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
GREMLINS_FILE = os.path.join(HOOK_DIR, "known-gremlins.md")
KUBECONFIG_PATH = "/home/lmpeixoto/repos/AdamastorX/platform/terraform/kubeconfig"


def build_context() -> str:
    try:
        with open(GREMLINS_FILE, "r", encoding="utf-8") as f:
            gremlins = f.read().strip()
    except OSError as e:
        # Fail open with a visible note rather than silently saying
        # nothing -- a missing/unreadable file is itself worth surfacing,
        # not swallowing.
        gremlins = f"(could not read {GREMLINS_FILE}: {e})"

    return (
        "## AdamastorX session brief (backlog #150, convenience only)\n\n"
        f"KUBECONFIG is set to `{KUBECONFIG_PATH}` for this session via "
        "`.claude/settings.json`'s `env` block (not by this hook) -- "
        "`kubectl` should work without a manual export. If it doesn't, "
        "that block may need re-adding or the folder may need "
        "(re-)trusting.\n\n"
        "### Known gremlins worth reading, not rediscovering\n\n"
        f"{gremlins}\n"
    )


def main():
    # Best-effort read of the payload; SessionStart's exact fields aren't
    # needed for what this hook does, so a malformed/absent payload still
    # gets a context brief rather than silently doing nothing.
    try:
        json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        pass

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": build_context(),
        }
    }
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
