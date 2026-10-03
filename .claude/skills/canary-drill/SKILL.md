---
name: canary-drill
description: Run or inspect a canary rollout drill against api's Argo Rollout (backlog #136, ADR 0043). Use when asked to run a canary drill, exercise the canary/SLO gate, check on a live rollout, or record a dated drill-log entry in platform/docs/runbooks/canary.md. Encodes the exact kubectl argo rollouts sequence, the #46 baseline timings, the whole-Service-scrape gotcha, and the dated-postscript recording convention — do not improvise a different sequence or invent new thresholds.
---

# Canary drill

`api` runs as an Argo Rollouts `Rollout` (`kubernetes/api/rollout.yaml`),
not a plain `Deployment` — canary + automated Prometheus analysis
(`kubernetes/api/analysistemplate.yaml`, `api-slo-check`) exists because a
stuck `CrashLoopBackOff` once sat invisible for 95 minutes while the old
pod kept serving (backlog #35). The full mechanism and its live-verified
selfHeal behavior are in `platform/docs/runbooks/canary.md` — read that
file if this Skill's summary isn't enough context for a judgment call.

This Skill exists so the drill is run the same way every time, not
rediscovered or improvised each session.

## Preconditions

- `kubectl argo rollouts` plugin present (`kubectl argo rollouts version`).
  If missing, install the release matching the live controller's image tag
  (`kubectl get deploy -n argo-rollouts -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'`),
  from `https://github.com/argoproj/argo-rollouts/releases/download/<tag>/kubectl-argo-rollouts-linux-amd64`.
  Installing the CLI locally is not a cluster mutation — do this without
  asking.
- Never run `promote`/`abort`/`retry`/a live image or resource-limit edit
  against the real cluster without explicit human confirmation for that
  specific action (WORKFLOW.md safety rule). `get`/`kubectl describe`/
  `kubectl logs`/`kubectl top` are always safe to run unprompted.

## Read-only inspection (always safe, no confirmation needed)

```bash
# Current state of the live Rollout
kubectl argo rollouts get rollout api -n api

# Live-watch a rollout in progress
kubectl argo rollouts get rollout api -n api --watch

# Pod-level detail during a step
kubectl describe pod -n api <canary-pod-name>
kubectl top pod -n api
```

`get` alone tells you: current step (n/4), `SetWeight`/`ActualWeight`,
which ReplicaSet is `stable`, and the full revision history with each
past `AnalysisRun`'s verdict. A `Healthy` status at `Step: 4/4`,
`SetWeight: 100` means no drill is in progress right now — that's the
expected steady state between drills, not an error.

## The drill sequence (mutating — requires human confirmation first)

Two drill shapes, per the #136 drill log — alternate clean and induced-fault
runs so the abort path stays exercised too, not just the happy path.

**Clean promotion**: force a real new ReplicaSet revision through the
existing canary + `api-slo-check` analysis gate without a functional
change — e.g. a pod-template annotation touch on the Rollout
(`adamastorx.io/canary-drill: "<date>-drill-N-clean-promotion"`), merged
as a real PR like any other change (never a live unmanaged `kubectl
patch` — GitOps is the source of truth).

```bash
kubectl argo rollouts get rollout api -n api --watch
# once at Paused/setWeight 50 and the analysis has started:
kubectl argo rollouts promote api -n api          # skip remaining wait/analysis
kubectl argo rollouts promote api -n api --full   # or straight to 100%
```

**Induced fault (automatic abort)**: reproduce the real #35 shape —
a labeled, TEMPORARY `limits.cpu: 500m` on the Rollout's pod spec
(cgroup-throttled JVM cold start, misses the liveness probe's ~80s
budget), committed, merged, watched, then reverted in a follow-up PR
immediately once the abort is confirmed. Do not apply this live and
unmanaged.

```bash
kubectl argo rollouts get rollout api -n api --watch
# watch it fail readiness/liveness and auto-abort at progressDeadlineSeconds: 180
kubectl argo rollouts abort api -n api            # manual equivalent, if needed
kubectl argo rollouts retry rollout api -n api    # to retry after a fix, no new image bump
```

## The #46 baseline — compare every drill's timing against this

- **Clean promotion**: pod creation → `RolloutHealthy` in **2m56s**
  (original #46 finding, 2026-07-30). Drill 1 (2026-08-16) measured
  **3m00s** — treat anything within a few seconds of this as "matches
  baseline, no real divergence," not a regression to chase.
- **Induced-fault abort**: pod creation → automatic abort in **3m01s**,
  matching `progressDeadlineSeconds: 180` almost exactly (this is
  `progressDeadlineAbort` firing, not the Prometheus analysis — the
  canary pod never becomes Ready, so it never receives a request and the
  analysis metrics never see it). Drill 2 (2026-08-16) also measured
  **3m01s** — an exact match, no divergence.
- A real divergence worth investigating: elapsed time more than ~30s off
  either baseline, or an abort reason that isn't
  `ReplicaSet "..." has timed out progressing.` / `RolloutAborted:
  Rollout aborted update to revision N.` for the fault case.

## The whole-Service-scrape ambiguity — record honestly, every time

`api-slo-check`'s analysis queries Prometheus scraping `api`'s **whole
Service** (aggregate traffic across every pod behind it), not the canary
pod in isolation (ADR 0014 — Prometheus scrapes the Service DNS target).
This means the analysis **cannot distinguish** "the new canary pod is bad"
from "the old stable pod got worse" purely from the SLI numbers, in the
case where the canary pod *is* passing readiness and receiving real
traffic. It only cleanly isolates the canary when:

- the canary never passes readiness at all (`progressDeadlineAbort`
  catches this instead, not the Prometheus analysis — this was true for
  every induced-fault drill run so far, #46's original and drill 2
  alike), or
- the canary is unambiguously the sole cause of a real SLI breach.

**Every drill-log entry must say plainly whether this ambiguity was live
in that specific run** — most runs so far have not had it in play (both
pods were healthy and serving throughout the clean runs; the canary never
received traffic in the fault runs), but that is a fact about each run,
not a property of the mechanism that can be asserted once and reused.
Per-pod scrape labels would close this gap — real, named, un-scheduled
follow-on work, not implemented, per the original AC's instruction to
reuse the exact existing PromQL expressions rather than invent a new
scrape/label shape alongside them.

## Recording the drill — the dated-postscript convention

Every drill is a new dated entry appended to `platform/docs/runbooks/
canary.md`'s "Drill log (backlog #136, M16 ADR 0043)" section, **never**
an edit to a past drill's own entry. Each entry states, in this order:

1. **Trigger** — the exact real change (issue/PR number, e.g.
   `platform#182`), and whether it was a clean or induced-fault run.
2. **Timeline** — real timestamps from the Rollout's own
   `status.conditions`/pod creation time, not estimated: pod created →
   step reached → (analysis started/`Status`) → `Healthy`/aborted.
3. **Elapsed, compared to the #46 baseline** — stated explicitly as
   "matches" or "diverges by Xs," never left implicit.
4. **Collateral check** — the previous stable pod's restart count and
   the `api` Application's sync/health status throughout (confirms no
   selfHeal fight, matching the original 2026-07-30 finding).
5. **Whole-Service-scrape note** — explicitly say whether the ambiguity
   was or wasn't in play for this specific run, per the section above.
6. **Fault revert** (induced-fault runs only) — confirm the revert PR
   number and that the diff against the pre-drill commit is empty.

## What this doesn't cover

- `clinvar-service` stays a plain `Deployment`, not migrated to a
  Rollout — see `rollout.yaml`'s own comment.
- This Skill does not decide *when* a drill is due — that cadence lives
  in ADR 0043 / the backlog #136 item, not here.
