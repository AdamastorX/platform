# Rolling back a deploy (backlog #37)

Not an alert-linked runbook (see `observability/runbooks/README.md` for
those — one per alert defined in backlog #21) — this is a plain
operational procedure, proven once for real rather than left as an
assumed-to-work idea.

## Which path applies (backlog #46 update)

**`api` specifically** now goes through Argo Rollouts, not the plain
procedure below. Two real, distinct situations:

- **A canary that's still in progress or just aborted** (a bad image
  bump that hasn't been reverted in git yet): use
  `docs/runbooks/canary.md`'s `kubectl argo rollouts abort`/`promote`
  commands. This is faster (no PR needed to stop bad traffic — the
  canary's own `setWeight`/analysis gate already keeps the bad version
  at partial or zero traffic) and is what backlog #46 was built for:
  automated detection turns the #35 CrashLoopBackOff shape into an
  automatic abort before a human even needs to run either command.
- **A bad version that already fully promoted** (the canary passed
  analysis but the regression only showed up later, or reverting a
  design/behavior decision entirely): the procedure below still
  applies unchanged — edit `kubernetes/api/rollout.yaml`'s image tag
  back to the previous known-good SHA, PR, merge, `refresh=hard`. Argo
  Rollouts runs that reverting bump through the same canary + analysis
  gate as any other deploy, so it gets the same automated safety a
  forward deploy does, not a bypass of it.

Every other service here (`workers`, `clinvar-service`) is still a
plain `Deployment` — the procedure below applies to them unchanged, no
`kubectl argo rollouts` commands involved.

## Procedure

Every deploy here is a one-line image-tag bump in
`kubernetes/<service>/deployment.yaml` (ADR 0009), merged to `main`,
picked up by ArgoCD. Rolling back is the same shape in reverse:

1. Edit `kubernetes/<service>/deployment.yaml`, set the `image:` tag
   back to the previous known-good SHA (check `git log --oneline --
   kubernetes/<service>/deployment.yaml` for it).
2. Open a PR, get it merged.
3. Force an immediate ArgoCD sync rather than waiting for the poll
   interval: `kubectl annotate application <service> -n argocd
   argocd.argoproj.io/refresh=hard --overwrite`.
4. `kubectl rollout status deployment/<service> -n <namespace>` until
   it reports success.

No `argocd app rollback` command was used — this repo's ArgoCD
Applications are declarative from git (ADR 0003), so "rollback" here is
just "revert the commit," not a separate imperative mechanism.

## Real timing (drilled live, backlog #37, 2026-07-26)

Exercised against `gateway` (stateless, no DB, no consumer group — the
lowest-blast-radius of the four app services, chosen deliberately for
the drill):

- **Rollback** (current image → previous image, PR #44): **54s** from
  the `refresh=hard` annotation to `kubectl rollout status` reporting
  success.
- **Roll-forward** (previous image → current image again, PR #46):
  pod `Ready` at **57s** of age; total wall-clock from PR merge to
  `Ready` was closer to ~80-90s once the real lag between the
  `refresh=hard` annotation and ArgoCD actually detecting/applying the
  new git spec is included — the annotation is not instantaneous, a
  first `kubectl rollout status` call right after annotating can report
  "successfully rolled out" against the *old*, not-yet-updated
  Deployment spec (observed directly during this drill). Re-check
  `kubectl get deployment <service> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  actually shows the new tag before trusting a fast `rollout status`
  result.

Both directions confirmed via the live cluster: correct image tag on
the running pod, `1/1 Ready`, no manual intervention beyond the steps
above.

## What this doesn't cover

- A rollback that also needs a database migration reverted (none of
  the four app services have hit this yet — Flyway migrations here are
  additive so far).
- Multi-service rollback ordering, since each service's deploy is
  currently independent (no cross-service version coupling documented).
