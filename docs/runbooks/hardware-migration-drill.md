# Pre-migration restore drill on the new host (backlog #153, ADR 0045)

Not an alert-linked runbook (see `observability/runbooks/README.md` for
those) — like `backup-restore.md` and `flannel-restore.md`, this is a
plain operational procedure, written *before* the drill is executed, per
the same discipline ADR 0040 established for `flannel-restore.md`: a
risky infra change gets a written, rehearsed plan first, not improvised
on the day. This document is the required precondition for #153 itself
— it does not touch the live cluster, and #153's own drill must not touch
the live *production* cluster on the old host either (see "What this
drill does not do," below).

ADR 0045 recorded the go decision: migrate off the T460s to the owner's
new, already-available, genuine multi-node hardware, carrying #94's
Prometheus history across now via the same PVC-copy pattern
`flannel-restore.md` already proved, rather than waiting for the 30-day
retention window to close on its own. This document is that pattern's
next real application — a second host, not a second CNI, but the same
underlying risk (moving durable state across a destructive
create/destroy boundary) and the same answer (rehearse it, verified live,
before it's load-bearing).

## What this drill proves, and what it does not

**Proves**: the restore path — Terraform bring-up on the new host,
ArgoCD reconciling the full platform from git, and every piece of durable
state (3 Postgres instances, Prometheus's 30-day history) landing intact
— actually works on the new hardware, with a real, measured RTO, before
any live cutover touches production data.

**Does not**: this is a drill, not the migration. It runs against a
**fresh, disposable target** — the new host, provisioned from scratch,
verified, then torn down again (or left standing empty) — never against
the live T460s cluster, and the live cluster is not touched, degraded, or
even synced against during this drill. #154 (the actual cutover) is a
separate, later, one-way action.

## Step one of this drill: real multi-node Terraform (built, platform#206)

`platform/terraform` now supports real agent hosts —
`var.agent_hosts` (a list, `for_each` per host, not `count`, so adding/
removing one host never touches another), a `null_resource.k3s_agent`
per entry, `depends_on` the server resource so no agent races the
server's first boot, join token fetched off the server the same
gitignored-local-artifact way `kubeconfig` already is. Full design and
the one-time per-agent host-prep steps (sudoers, the agent install
script, the `agent-env` file the install script sources) are in
`terraform/README.md`'s own "Multi-node: adding agent hosts" section —
this document doesn't repeat them, to avoid the two copies drifting.

This concrete drill's topology (2026-08-30, ADR 0045's real-world
instantiation): the new NucBox K8 Plus becomes the sole k3s **server**
(`target_host`) — this drill runs single-node against it first, no
agent yet. The T460s only rejoins as a real physical **agent**
(`agent_hosts`) *after* #154's real cutover frees it from production
duty, per this document's own "What this drill does not do" section —
not during this drill.

Before anything below: `terraform apply` against the NucBox alone
(`target_host` = the NucBox's address, `agent_hosts` left at its `[]`
default) must produce one healthy `Ready` node.

## Real inventory: what must survive, carried forward from `flannel-restore.md`

**Pre-flight, before anything else in this section: run `kubectl get pvc
-A` against the live old-host cluster and diff the real result against
the table below — do not start from the table as if it were current.**
The PVC classification `flannel-restore.md` built for the Cilium rebuild
applies here with the same reasoning — a full node-loss/host-move wipes
everything node-pinned (`local-path`) either way — but it is carried
forward from `flannel-restore.md`'s 2026-08-09
inventory, and real services have shipped since (`securityContext`
hardening #142, dashboards, possibly new PVCs) that this copy has not
re-checked.

| Namespace | PVC | Classification |
|---|---|---|
| `api` | `data-postgresql-0` | **Must restore** — `work_items`, source of truth. Use `backup-restore.md`'s `pg_dump`/`pg_restore` mechanism (simpler and already-proven for cross-host moves — no raw PVC copy needed). |
| `clinvar` | `data-clinvar-postgresql-0` | **Must restore** — `clinvar_release`/`clinvar_variant_index`, source of truth. Same `pg_dump`/`pg_restore` mechanism. |
| `watchlist` | `data-watchlist-postgresql-0` | **Must restore** — `subscriptions`/`deliveries`, source of truth. Same mechanism. Re-check whether real subscription data exists yet — `backup-restore.md`'s own restore proof is still only schema-proven, not row-level, per its own stated gap. |
| `prometheus` | `prometheus-server` | **Must restore — this drill's one hard requirement per ADR 0045.** #94's 30-day history. Use the PVC-copy-out/copy-in pattern below, not `pg_dump` (Prometheus has no such export). |
| `mimir` | `mimir-data` | Optional, low priority — same reasoning as `flannel-restore.md`. |
| `kafka` | `data-kafka-controller-0` | Acceptable loss for plain consumer groups; **confirm `aggregator`'s Streams changelog-rebuildability** before treating as fully disposable, same open question `flannel-restore.md` named and never closed. |
| `loki` / `tempo` / `pyroscope` | telemetry PVCs | Acceptable loss — regenerates from live traffic. |
| `clinvar` | `clinvar-service-refdata` | Acceptable loss — re-ingestible cache, ~7 min regen via `POST /internal/clinvar/ingest`. |

## Real gap, stated plainly: Terraform state has no off-host copy

Backlog #99 (off-node backup of the pg_dump PVCs *and* the local
Terraform state) is **deliberately deferred**, unchanged by ADR 0045 —
it needs a real object-storage account/credentials the owner has chosen
not to provision yet. Concretely: `platform/terraform/terraform.tfstate`
(plus its `.backup`) exists **only on the old host's local disk today**,
the same single-point-of-failure class #99 exists to close and has not
yet closed. This drill does not fix that gap, and the migration itself
must not accidentally rely on it being fixed. Before any real work
here: **manually copy `terraform.tfstate`/`terraform.tfstate.backup` off
the old host** (a plain `scp`/USB copy is enough — this is not #99's
real fix, just not losing the one copy that exists while it's being
moved). Track #99 as still open after this migration, not silently
resolved by it.

## Restore mechanism for Prometheus (the PVC-copy pattern)

Identical to `flannel-restore.md`'s proven mechanism, same hard-won
correction included (`runAsUser`/`runAsGroup` match, not a generic
`busybox` default — the `local-path`/`hostPath` `fsGroup` gap that
caused #94's real 2026-08-09 `CrashLoopBackOff`):

1. **On the old host, before touching anything**: scale
   `prometheus-server` to 0. A temporary pod, `securityContext.runAsUser`/
   `runAsGroup` set to match the real Deployment spec (`65534`, read
   from the live spec, not assumed), mounts `prometheus-server`'s PVC
   and `kubectl cp`s `/data` to local disk outside the cluster.
2. **New host**: `terraform apply` (multi-node, per the precondition
   above), ArgoCD root app reconciles the full platform from git,
   `prometheus` namespace/PVC comes up empty.
3. Scale `prometheus-server` to 0 on the new host too. A second
   temporary pod, same `runAsUser`/`runAsGroup` match, `kubectl cp`s the
   copied `/data` back in.
4. Scale `prometheus-server` back to its real replica count.
5. **Verify, don't assume**: real `/api/v1/query?time=<past offset>`
   calls at several day-old offsets (1/2/3/4/5 days back, the same
   technique #94's own PVC resize and `flannel-restore.md` both already
   proved), confirming real retained history survived the move intact
   and the retention clock did not reset.

## Restore mechanism for the three Postgres instances

Use `backup-restore.md`'s already-proven `pg_dump`/`pg_restore`
mechanism directly — simpler than a raw PVC copy for a cross-host move,
and already measured (0.31s/46.4s/0.308s RTO for `api`/`clinvar`/
`watchlist` respectively on the existing data volumes):

1. Trigger each `*-postgresql-backup` CronJob manually
   (`kubectl create job --from=cronjob/<name>`) rather than waiting for
   the nightly schedule, or use the most recent real dump already on the
   backup PVC if it's fresh enough.
2. Copy the dump files off the old host (`kubectl cp` via a temporary
   pod matching the backup PVC's own `runAsUser`, same lesson as above).
3. On the new host, once the real `postgresql`/`clinvar-postgresql`/
   `watchlist-postgresql` Applications are `Synced`/`Healthy` with fresh
   empty databases: `pg_restore --no-owner --no-privileges -h <host> -U
   <app-user> -d <database> <dump file>` into each real instance
   (**not** a scratch namespace this time — this drill's whole point is
   proving the real target instances, unlike `backup-restore.md`'s
   original scratch-namespace proof).
4. **Verify, don't assume**: real row counts against what the old host
   showed at dump time, plus at least one spot-checked row per instance
   (the same `rs80357906` BRCA1 check `backup-restore.md` already
   established for `clinvar`).

## Post-restore acceptance: run backlog #123's checklist in full

Once Terraform, ArgoCD reconciliation, and the restores above are all
complete on the new host, run every line of `flannel-restore.md`'s own
"Post-restore acceptance checklist (backlog #123)" section against the
new host, unmodified — the same six business-path checks (real ClinVar
lookup, a real `/work-items` POST observed consumed, the full Kafka
topic list, `probe_success` all `1`, `/aggregates` non-empty with a
fresh `priceAsOf`, a real `clinvar.ingestion.completed` fan-out reaching
a real `deliveries` row). **A component being Running/Ready/Synced is
not this checklist's bar** — the same #122 lesson that motivated writing
#123 in the first place: every check on the original #49 rebuild passed
and the system was still broken in three real places afterward.

## Recording the result

Per #153's own acceptance criteria: a real, measured RTO for the whole
drill (wall-clock, start of `terraform apply` on the new host to the
last acceptance-checklist line passing), and any gap found on the new
hardware resolved *before* #154's real cutover proceeds — not carried
forward as a known issue into the live move. Record the result as a
dated postscript to this document, the same convention
`flannel-restore.md`'s own "What 'rehearsed' means" section and
`backup-restore.md`'s "Real restore, proven live" section both already
use — a real date, real commands, real numbers, not a checklist eyeballed
after the fact.

## What this drill does not do

- Does not touch, degrade, or sync against the live T460s production
  cluster at any point.
- Does not fix #99 — the Terraform-state off-host-backup gap stays open
  and real after this drill, tracked separately.
- Does not itself execute the cutover — #154 is a distinct, later,
  one-way action gated on this drill passing in full.

## Real run, proven live (2026-08-30)

The NucBox K8 Plus (single physical node, `target_host` — the T460s
rejoins later as a real `agent_hosts` entry only after #154 frees it,
per this document's own topology section above) had already been
`terraform apply`'d and host-prepped in an earlier session; this run
picks up from `bootstrap/root-app.yaml` onward, with #123's checklist
run against it end to end for the first time.

**Real gremlins hit and fixed along the way, not glossed over**:

- `k3s.yaml` on the new host resets to `0600` on every server restart
  (k3s rewrites it, undoing the install script's one-time `chmod 644`)
  — `terraform/README.md`'s "Moving to another machine" section doesn't
  yet mention this; worth a follow-up doc fix.
- The k3s server's auto-generated TLS cert had no SAN for the host's
  Tailscale address — fixed with `--tls-san` added to the install
  script's `INSTALL_K3S_EXEC` and a reinstall (in-place, no data loss).
- `kubectl cp <localdir> pod:/data` nests the source directory one level
  deep instead of copying its contents (needs a trailing `/.` on the
  source, or a `mv` fixup after) — hit once on the Prometheus copy-in,
  worth calling out explicitly next time this pattern is reused.
- M13/mimir/`*-network-policies` Applications are deliberately not
  `automated` (owner-gated, `docs/SESSION_STATE.md`'s own documented
  reasoning) — a fresh cluster needs each one triggered manually
  (`kubectl patch application <name> -n argocd --type merge -p
  '{"operation":{"sync":{}}}'`) after `root-app.yaml` lands, not assumed
  to reconcile on their own. A few of these also needed their target
  namespace created by hand first (`CreateNamespace=true` raced the
  first sync attempt on a truly fresh cluster).
- The default `namespace-quota` ResourceQuota requires every pod to
  state `resources.requests/limits.memory` explicitly — any throwaway
  debug/copy pod needs these set or the API server rejects it outright.
- Two synthetic/legacy CronJob Applications (`postgresql-backup`,
  `clinvar-postgresql-backup`, `watchlist-postgresql-backup`) never
  report ArgoCD health as `Healthy` — a CronJob-only Application has no
  real readiness signal for ArgoCD's health check to key on, stays
  `Progressing` indefinitely. Cosmetic, not a real gap (confirmed all
  three CronJobs run and prune correctly once triggered).
- `postgresql-backup`'s CronJob on the *old* host had three real,
  actual `Failed` runs (today, ~11:17, clustered ~14s apart) with 0-byte
  dump files — consistent with the CronJob controller's own missed-run
  catch-up behavior after the host had been powered off for several
  days, colliding with Postgres not yet being ready. Last known-good
  dump for all three instances: **2026-08-25** (5 days stale, still
  inside the 14-day retention window, used for this drill's restore).
  Real, separate finding — not caused by this drill, not fixed by it,
  worth its own backlog item so the daily backup doesn't stay silently
  broken.
- `pg_restore` into the real target instances (not a fresh scratch
  database) throws real "already exists" errors for every schema
  object, because Flyway had already migrated the fresh database to the
  current schema before the restore ran — expected, once seen: use
  `--data-only`, or accept the "errors ignored" data-still-loads
  behavior `pg_restore` already has, rather than assuming this drill's
  own "restore into the real target instance" design was broken.
- `workers`' own KEDA `ScaledObject` has `activationLagThreshold: 10` —
  a single test message doesn't cross it, `workers` never scales up
  from 0. Needed enough real messages (12 more, 13 total) to prove the
  consumption path; not a bug, just a threshold to know about before
  assuming a single-message check should work here the way it did
  against the original, already-warm cluster.
- Business-path checks that assume `app: api`-labeled pods can freely
  call other in-cluster services are wrong once `CiliumNetworkPolicy`
  egress is enforced: a synthetic pod sharing that label inherits the
  real `api` Deployment's own narrow egress allow-list (DNS, clinvar,
  kafka only) and can't reach Traefik itself. Route through Traefik
  from an *unlabeled* pod with a `Host:` header override instead of
  DNS (public DNS still points at the T460s, not yet cut over) to test
  the real ingress path.

**Backlog #123 checklist result, run against the NucBox for the first
time**:

1. Real ClinVar lookup (`rs80357906`) — **PASS**, `200`,
   `"clinicalSignificance":"Pathogenic"` (after a real, triggered
   `POST /internal/clinvar/ingest` run: 1m25s, 4,467,990 records
   scanned, 2,895,533 index rows built — `clinvar-service-refdata`'s
   PVC is deliberately not carried across, per this document's own
   inventory table, and regenerates exactly as documented).
2. Real `/work-items` POST consumed by `workers` — **PASS**, all 13
   real messages (1 plus 12 to cross the KEDA activation threshold
   above) logged consumed with matching ids/markers.
3. Full Kafka topic list — **PASS**, 10/10 exact match.
4. `probe_success` all `1` — **PARTIAL, real and expected gap**: only
   the DNS-independent `blackbox-kafka-tcp` probe passes (1/7); the six
   `https://*.local.adamastorx.test` HTTP probes all fail because public
   DNS for those hostnames still resolves to the T460s, not the NucBox
   — a real, correctly-scoped-out-of-this-drill gap that #154's own
   cutover (which does the DNS move) is what actually closes it, not
   this drill.
5. `GET /aggregates` non-empty, fresh `priceAsOf` — **PASS**, 5 real
   tickers, `priceAsOf` seconds old (real `finnhub-api-key` copied over
   from the live T460s Secret rather than re-provisioned, since it's
   the same real third-party credential either way).
6. Real `clinvar.ingestion.completed` fan-out reaching a real
   `deliveries` row — **PASS**, real subscription created
   (`variantAnnotation:17:43057062:T:TG`, the same BRCA1 variant #1's
   spot-check uses), a real schema-valid message produced on the topic,
   a real `SENT` delivery row confirmed matching.

**5 of 6 checks PASS outright; the 6th (probe_success) fails for a
reason genuinely out of this drill's scope** (DNS cutover, #154's job)
rather than a data or mechanism problem — consistent with "any gap
found on the new hardware resolved before #154's real cutover proceeds"
this document's own bar sets, since the one open item here is already
correctly assigned to #154, not silently carried forward as unexplained.

**Prometheus PVC-copy, measured**: T460s scale-to-0 at 20:56:29 UTC,
`kubectl cp` of the live `/data` (8.8G) took 2m16s locally, restored
onto the T460s (back to `Ready`) by 20:59:23 — **2m54s real production
downtime** for the copy-out half alone. Copy-in to the NucBox (same
8.8G, over Tailscale rather than localhost) took 7m48s; NucBox
`prometheus-server` back `Ready` at 21:11:46. History verified intact
across 1/2/3/5/10/20-day-old offsets, matching the live T460s
instance's own series counts almost exactly (a same-minute first check
returned `0` series for the 1–3-day offsets — not real data loss, the
freshly-copied 8.7G TSDB just hadn't finished being indexed yet
immediately after the pod's own readiness probe passed; a re-check a
few minutes later matched cleanly). #94's 30-day retention clock is
carried across intact, not reset.

**Postgres restore, measured**: all three instances restored from the
real, last-known-good 2026-08-25 dumps into their real NucBox target
databases (not a scratch namespace). `clinvar_variant_index`
(2,895,533) and `clinvar_release` (14) match the live T460s source
exactly; `work_items` (245,838 restored vs. 252,651 live) and
`watchlist.deliveries` (0 restored vs. 3 live) are lower, consistent
with 5 real days of growth since the dump was taken, not restore loss.
BRCA1 (`rs80357906`) spot-checked byte-for-byte identical between the
live T460s source and the NucBox restore.

**Gaps found, explicitly not resolved by this drill, tracked
separately rather than silently carried forward**:
- The `postgresql-backup`/`clinvar-postgresql-backup`/
  `watchlist-postgresql-backup` CronJobs' real `Failed` runs on the old
  host (see above) — worth its own backlog item.
- `probe_success`'s six DNS-dependent failures — #154's own scope, not
  this drill's.
- #99 (Terraform-state off-host backup) — unchanged, still open, a
  manual copy was made for this drill only, not a standing fix.

No end-to-end wall-clock RTO recorded for the *whole* drill (Terraform
apply through the last checklist line) — the NucBox's own `terraform
apply` and host-prep happened in an earlier, separate session not
timed as part of this run. The individual, real, measured components
above (Prometheus copy, Postgres restore, checklist) are the honest
numbers available from this specific session.
