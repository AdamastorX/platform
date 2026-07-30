# Canary deploys and the automated SLO gate (backlog #46)

`api` is now an Argo Rollouts `Rollout`
(`kubernetes/api/rollout.yaml`), not a plain `Deployment`. The reason is
a real incident: during the #35 resource-governance work, a routine
rollout sat in `CrashLoopBackOff` for **95 minutes** while the old pod
kept serving traffic, because Kubernetes' default rolling update leaves
the old ReplicaSet up and nothing about that state is visibly "down" —
nothing alerted, nobody noticed until someone looked. A canary with an
automated analysis step turns that same failure shape into an automatic
abort with a reason attached, usually within minutes.

## What changed

- `kubernetes/api/rollout.yaml`: same pod spec as the old
  `deployment.yaml` (image, env, probes, resources — nothing about the
  running container changed), `kind: Rollout` with a `canary` strategy:
  `setWeight: 50` → `pause: 30s` → `analysis` (below) → `setWeight: 100`.
  `maxSurge: 1`/`maxUnavailable: 0` so, at `replicas: 1`, the 50% step is
  a real second pod added alongside the still-serving one, not a
  replacement — both share the existing `api` Service/selector
  unchanged, so traffic actually round-robins across both during the
  canary window.
- `kubernetes/api/analysistemplate.yaml` (`api-slo-check`): queries the
  live Prometheus (`prometheus-server.prometheus.svc.cluster.local`,
  same instance every dashboard/alert already reads) for api's own two
  SLIs from ADR 0020's table — non-5xx rate (the exact ratio PromQL
  from `argocd/apps/prometheus.yaml`'s `ApiHighErrorRate` rule, not a
  new expression) and p95 latency (the exact `histogram_quantile(0.95,
  ...)` expression already shipped in api's Grafana dashboard,
  `argocd/apps/grafana.yaml` — alerting_rules.yml has no latency rule to
  copy from, stated openly in the file's own comment rather than
  pretending one exists). 4 measurements, 30s apart, `failureLimit: 0` —
  any single breach fails the canary.
- `argocd/apps/argo-rollouts.yaml`: the controller itself, installed the
  same Helm-Application-with-inline-values pattern as every other
  platform component (ADR 0003).
- `progressDeadlineSeconds: 180` + `progressDeadlineAbort: true` on the
  Rollout: this is what actually catches the #35 shape. A canary pod
  that never passes readiness never receives a single request (kube-proxy
  only routes to Ready endpoints), so the Prometheus-based analysis
  above has no bad data to see — this deadline is the mechanism that
  fires regardless, turning "stuck" into an automatic abort instead of a
  `Degraded` status a human has to notice. The two safety nets are
  complementary, not redundant: analysis catches "canary is up and
  serving but degraded"; the deadline catches "canary never came up at
  all."

## selfHeal interaction, resolved

**Confirmed live, not assumed: ArgoCD does not fight a canary in
progress, because nothing about the canary touches git-tracked spec.**

The Rollout's git-tracked `spec` (image, strategy, steps) doesn't change
during a canary — only its `status` and the ReplicaSets/Pods the
controller creates on its own change, and those aren't part of what
`selfHeal` diffs against git. Confirmed two ways during this work's own
live testing:

1. **ArgoCD's own default `argocd-cm` already ships Rollout-awareness
   out of the box.** `resource.customizations.ignoreResourceUpdates.argoproj.io_Rollout`
   and `...apps_ReplicaSet` (ignoring the
   `rollout.argoproj.io/desired-replicas` annotation) are present in
   this cluster's `argocd-cm` with **no project-added customization** —
   these are ArgoCD's compiled-in defaults (ArgoCD 2.4+; this cluster
   runs v3.4.5, ADR 0003). No `resource.customizations.health...` entry
   for `Rollout` exists either — meaning the correct Progressing/
   Paused/Healthy/Degraded status ArgoCD showed throughout every step of
   both live tests below came from ArgoCD's own native Go health
   assessment for the `argoproj.io/Rollout` kind, not a Lua script this
   project had to add. Nothing to configure; verified working, not
   assumed.
2. **A full canary cycle (setWeight → pause → analysis → setWeight 100)
   ran start to finish with the `api` Application reporting `Synced` the
   entire time** — see the live proof below. If selfHeal were fighting
   the in-progress ReplicaSet scaling, sync status would have flapped
   `OutOfSync`; it never did.

The one selfHeal interaction that **is** real, and was hit directly
while testing this (independently reproducing the same finding
`docs/SESSION_STATE.md` already recorded from chaos scenario 2):
**live-patching a tracked Application object's own spec (e.g.
`targetRevision`) without a git commit gets reverted by `root`'s own
selfHeal on its next reconcile**, because `root` manages every child
`Application` under `argocd/apps/` as one of its own tracked resources.
This bit the pre-merge live-test procedure below directly — patching
`api`'s `targetRevision` live got silently reverted back to `main` until
the same change was made as a real committed diff to `argocd/apps/api.yaml`
and `root` was given its own `refresh=hard` (not just the child) to pick
up the tracked-file change. Not a gap in this backlog item; the same
already-known, already-documented behavior, now confirmed to apply to
`api`'s Application object too, not just `root`'s own nested apps.

## Manual commands

Requires the `kubectl argo rollouts` plugin
(`https://github.com/argoproj/argo-rollouts/releases`, matched to the
chart's app version — `argocd/apps/argo-rollouts.yaml`'s pinned
`targetRevision`).

```bash
# Watch a rollout live
kubectl argo rollouts get rollout api -n api --watch

# Manually promote past the current step (skips the remaining wait/analysis)
kubectl argo rollouts promote api -n api
# ...or promote straight to 100% skipping all remaining steps
kubectl argo rollouts promote api -n api --full

# Manually abort (reverts weight to 100% stable immediately)
kubectl argo rollouts abort api -n api

# Retry a rollout that aborted (e.g. after fixing an AnalysisTemplate bug --
# see the live-test note below) without a new image bump
kubectl argo rollouts retry rollout api -n api

# Undo: same as any other rollback here (see rollback.md) -- edit
# kubernetes/api/rollout.yaml's image tag back to the previous known-good
# SHA, PR, merge, refresh=hard. Argo Rollouts runs that reverting bump
# through the same canary + analysis gate, same as a forward deploy.
```

## Live verification (2026-07-30)

Tested pre-merge via this project's own sanctioned exception (ADR
0003): `root` and `api`'s Application objects temporarily pointed at
this PR's branch, flipped back to `main` before merge (see PR
description). Real cluster, real Prometheus, real traffic from #45's
workload-generator.

**Good path — clean promotion.** Bumped `api`'s image to a real,
previously-deployed SHA to force a genuine canary (not a no-op). First
run's analysis errored on a real bug (below); after fixing it and
running `kubectl argo rollouts retry`:

- Canary pod passed readiness, `setWeight: 50` reached (1 stable + 1
  canary pod, both serving) — confirmed via `kubectl argo rollouts get
  rollout`.
- Analysis (`api-994d8b466-2-2.1`) ran 4 measurements against live
  Prometheus, both metrics within threshold, `Status: Successful`.
- `setWeight: 100`, old ReplicaSet scaled down, `RolloutCompleted`.
- **Elapsed, retry to `RolloutHealthy`: 2m56s** (`20:53:37Z` → `20:56:33Z`,
  from the Rollout's own `status.conditions` timestamps).
- `api` Application stayed `Synced` throughout — no selfHeal fight.

**Bad path — automatic abort.** Reproduced the exact #35
`CrashLoopBackOff` shape: set `resources.limits.cpu: 500m` on the same
pod spec (the real value that caused the original incident —
cgroup-throttled during JVM cold start, missing the liveness probe's
80s budget), no image change needed.

- Canary pod created `20:58:14Z`. Repeated liveness-probe failures
  (`connect: connection refused`, `read: connection reset by peer`),
  `restartCount` climbing, container exit code 137 — the same
  CrashLoopBackOff shape as the original incident, confirmed live via
  `kubectl top pod` showing CPU pegged at the 500m limit.
- **Automatic abort at `21:01:15Z` — elapsed 3m01s from canary pod
  creation**, matching the configured `progressDeadlineSeconds: 180`
  almost exactly (this is `progressDeadlineAbort` firing, not the
  Prometheus analysis — the canary pod never became Ready, so it never
  received a request and the analysis metrics never saw it, exactly the
  "complementary safety net" behavior documented above).
- **Abort reason (verbatim, from real cluster events/conditions)**:
  `ReplicaSet "api-cbc8749" has timed out progressing.` /
  `RolloutAborted: Rollout aborted update to revision 3`.
- **Previous good pod (`api-994d8b466-8cmgh`) confirmed serving
  uninterrupted the entire time**: `restartCount: 0`, running since
  before the bad canary even started (`20:53:38Z`) through well after
  the abort.
- `api` Application health correctly went `Degraded` (matching the
  Rollout's real aborted state) — expected and correct: the git-tracked
  spec still pointed at the bad resource limit at that point in the
  test, same as any other rollback needing a real revert.

**Real bug found and fixed live, not assumed away**: the first
analysis run errored (`reflect: slice index out of range`) because
Micrometer only emits an `outcome="SERVER_ERROR"` timeseries once api
has returned at least one real 5xx — on a healthy service that series
doesn't exist yet, so `sum(rate(...))` over it returns an *empty*
vector, not `0`. Alertmanager silently never fires on an empty
expression, so `ApiHighErrorRate` never needed a guard for this: an
`AnalysisRun` does, since it expects a concrete `result[0]`.
Fixed with the standard `... or vector(0)` idiom
(`analysistemplate.yaml`) — confirmed working on the retried run above.
Recorded here rather than silently absorbed, per this project's own
documentation convention.

**What's verified vs. what needs a human check post-merge**: both
directions above ran against this PR's actual final manifests (the
image/resource-limit values used for the two test runs were reverted to
the real production values — `206478af.../cpu: 1` — immediately after,
and the live cluster was confirmed back on a plain `Deployment` with the
real image before this PR was opened, so `api` was never left
mid-migration). Not independently re-verified after the final revert:
a *third* full canary cycle using the exact final committed manifests
byte-for-byte (the two live runs above used temporarily-edited image/
resource values mid-test, by construction, to force a real spec change
and a real failure). The mechanism itself (canary steps, analysis
provider, abort/promote, selfHeal non-interaction) is proven against
this exact codebase; a human merging this should do one real image bump
afterward and watch it, the same as any other first deploy.

## What this doesn't cover

- `clinvar-service` stays a plain `Deployment` (backlog #46's own
  "optionally" — not migrated here; see `rollout.yaml`'s own comment on
  why `api` was the one that mattered).
- The analysis measures `api`'s *whole Service* aggregate traffic
  (Prometheus scrapes the Service DNS target, not per-pod — ADR 0014),
  not the canary pod in isolation. It cannot distinguish "the new pod is
  bad" from "the old pod got worse" by SLI numbers alone if the canary
  pod *is* passing readiness and receiving traffic — real, stated
  follow-on work (per-pod scrape labels) would close this, not done
  here to keep to the AC's "reuse the exact existing expressions"
  instruction rather than inventing a new scrape/label shape alongside
  it.
- Pre-merge testing left a harmless empty `argo-rollouts` namespace and
  the chart's CRDs behind on the live cluster (ArgoCD's prune doesn't
  delete namespaces it created via `CreateNamespace=true`, and the
  chart's own `keepCRDs: true` default is deliberate — CRDs are
  cluster-wide, so deleting them on an Application prune would delete
  every `Rollout`/`AnalysisTemplate` object cluster-wide, not just this
  one). Merging this PR re-creates both cleanly through the real
  `argo-rollouts` Application; the leftover empty namespace/CRDs from
  the pre-merge test can be left in place (harmless, zero live custom
  resources in them at merge time) or cleaned up by a human with
  cluster-admin access, whichever is convenient.
