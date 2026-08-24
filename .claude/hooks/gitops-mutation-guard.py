#!/usr/bin/env python3
"""ADAMASTORX PreToolUse safety hook: GitOps mutation guard.

Mechanically enforces WORKFLOW.md's Safety rule: never run a mutating
kubectl/terraform command against live cluster/infra state without explicit
human confirmation for that specific action. Wired as a PreToolUse hook
(matcher: Bash) in ../settings.json.

Design summary (see adamastorx/.claude/WORKFLOW.md's Safety section and the
PR that introduced this hook for the full rationale and rejected
alternatives):

- Deny-list, not allow-list. Only the mutating verbs below require
  confirmation; everything else -- explicit read-only verbs, and any
  kubectl/terraform subcommand this script doesn't recognize -- is left
  alone. This mirrors the backlog item's own framing ("deny-lists mutating
  verbs ... while leaving read-only inspection unblocked") rather than
  trying to allow-list the universe of safe commands.

- Confirmation token: the literal marker `ADAMASTORX_CONFIRM_MUTATION=1`
  must appear in the exact command string being run (recommended usage: as
  a leading env-var assignment on the same line, e.g.
  `ADAMASTORX_CONFIRM_MUTATION=1 kubectl apply -f manifest.yaml`). A hook
  only sees the command about to run, not the surrounding conversation, so
  "confirmation" here means "a human explicitly asked, in this turn, for
  this exact marker to be attached to this exact command" -- it is
  per-invocation, matching WORKFLOW.md's "confirmation for that specific
  action" wording, not a session-wide toggle.

  As a secondary path, the same-named environment variable
  (`ADAMASTORX_CONFIRM_MUTATION=1`) already set in *this hook process's own
  environment* also counts. That path is for the owner's own shell (set
  before launching `claude`) and is not reachable by anything the model
  runs through the Bash tool -- Bash tool invocations don't propagate
  `export`s back up into the hook's parent process. It exists for
  batch/maintenance sessions, not as the documented everyday mechanism.

- Honest limitation, stated plainly: since the model composes the very
  command string this script inspects, a model that simply always prepends
  the marker would defeat this check -- this is NOT a security boundary
  against an adversarial or compromised model. It is a deliberate speed
  bump for a single-owner personal project: it converts "ran a destructive
  command because it seemed like the natural next step" into "had to
  deliberately type an unusual, self-documenting marker that a human would
  only ask for when they'd actually decided to confirm that specific
  action." For a personal homelab with one operator who is also the sole PR
  reviewer, that's the right level of ceremony; it is not a multi-tenant
  security control and should not be treated as one.

- Stricter than the original WORKFLOW.md prose on purpose: the prose
  exempted "short-lived debugging" kubectl mutations (e.g. deleting a stuck
  pod). A hook cannot tell "short-lived debugging delete" apart from "a
  standing destructive change" -- both are `kubectl delete ...` -- so this
  hook collapses that nuance and requires the token for every mutating verb
  uniformly. That's what makes it a mechanically enforced rule instead of a
  judgment call delegated back to the model.
"""
import json
import os
import shlex
import sys

CONFIRM_TOKEN = "ADAMASTORX_CONFIRM_MUTATION=1"
CONFIRM_ENV_VAR = "ADAMASTORX_CONFIRM_MUTATION"

KUBECTL_MUTATING_VERBS = {
    "apply", "patch", "delete", "scale", "replace", "edit", "annotate", "label",
}
TERRAFORM_MUTATING_VERBS = {"apply", "destroy"}

# Flags that take a separate value token, so we don't mistake the value for
# the verb (e.g. `kubectl -n default apply -f x.yaml` -- "default" is not
# the verb). Not exhaustive; good enough for this project's real usage.
VALUE_FLAGS = {
    "-n", "--namespace", "--context", "--kubeconfig", "--server", "-s",
    "--as", "--as-group", "-o", "--output",
}

OPERATORS = {"&&", "||", ";", "|", "&"}


def split_segments(command: str):
    """Best-effort split of a shell command string into top-level segments
    on &&, ||, ;, |, & -- good enough for the simple, scripted invocations
    this project's sessions actually run. Not a full shell parser (no
    attempt to look inside $(...) or heredocs)."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars="&|;")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        # Unbalanced quotes etc. Fail closed: still scan the raw whitespace
        # split rather than silently skipping inspection.
        return [command.split()]

    segments = []
    current = []
    for tok in tokens:
        if tok in OPERATORS or (tok and set(tok) <= {"&", "|"}):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(tok)
    if current:
        segments.append(current)
    return segments


def find_program_and_verb(tokens, program_names):
    """Find the first occurrence of one of `program_names` (basename match,
    so `/usr/local/bin/kubectl` and `sudo kubectl` both work) in `tokens`,
    and return (program, verb) where verb is the first following non-flag
    token. Returns None if no program from `program_names` appears."""
    for i, tok in enumerate(tokens):
        base = os.path.basename(tok)
        if base in program_names:
            j = i + 1
            while j < len(tokens):
                t = tokens[j]
                if t in VALUE_FLAGS:
                    j += 2
                    continue
                if t.startswith("-"):
                    j += 1
                    continue
                return base, t
            return base, None
    return None


def segment_has_dry_run(tokens):
    return any(t == "--dry-run" or t.startswith("--dry-run=") for t in tokens)


def is_confirmed(command: str) -> bool:
    return CONFIRM_TOKEN in command or os.environ.get(CONFIRM_ENV_VAR) == "1"


def evaluate(command: str):
    """Return (blocked, reason, confirmed_mutation_seen)."""
    confirmed = is_confirmed(command)
    saw_confirmed_mutation = False

    for tokens in split_segments(command):
        if not tokens:
            continue
        found = find_program_and_verb(tokens, {"kubectl", "terraform"})
        if not found:
            continue
        program, verb = found
        if verb is None:
            continue

        mutating = (
            KUBECTL_MUTATING_VERBS if program == "kubectl" else TERRAFORM_MUTATING_VERBS
        )
        if verb not in mutating:
            continue  # read-only or unrecognized subcommand: never blocked

        if segment_has_dry_run(tokens):
            continue  # dry-run never touches live state

        if not confirmed:
            reason = (
                f"Blocked mutating command `{program} {verb}` "
                f"(segment: `{' '.join(tokens)}`). WORKFLOW.md's Safety rule "
                "requires explicit human confirmation for this specific "
                f"action. Re-run with the literal marker `{CONFIRM_TOKEN}` "
                f"attached to this command (e.g. `{CONFIRM_TOKEN} "
                f"{program} {verb} ...`), and only do so because a human "
                "explicitly confirmed this exact action in this turn."
            )
            return True, reason, False

        saw_confirmed_mutation = True

    return False, None, saw_confirmed_mutation


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # Can't parse the payload -- fail open. Breaking every tool call
        # over a hook-input format we don't understand is a worse failure
        # mode than occasionally missing a check.
        sys.exit(0)

    if payload.get("tool_name") != "Bash":
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command", "")
    if not command:
        sys.exit(0)

    blocked, reason, confirmed_mutation = evaluate(command)

    if blocked:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }))
        sys.exit(0)

    if confirmed_mutation:
        # Make the allow decision visible/auditable in the transcript
        # rather than silently proceeding.
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": (
                    f"Mutating kubectl/terraform command explicitly "
                    f"confirmed via {CONFIRM_TOKEN} marker."
                ),
            }
        }))
        sys.exit(0)

    # No mutating verb detected (or read-only) -- no decision, proceed
    # normally.
    sys.exit(0)


if __name__ == "__main__":
    main()
