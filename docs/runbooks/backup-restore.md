# Backup and restore for stateful data (backlog #23a)

Not an alert-linked runbook (see `observability/runbooks/README.md` for
those) — like `rollback.md`, this is a decision plus a plain operational
procedure, proven once for real rather than left as an assumed-to-work
idea. Written because an independent staff-engineer audit found that no
stateful component in this project had a documented or automated
backup/restore path at all (`docs/SESSION_STATE.md`).

## Scope: what has real state worth backing up

Three PostgreSQL instances hold source-of-truth data that cannot be
regenerated:

- `postgresql` (namespace `api`, database `api`) — owns `work_items`.
- `clinvar-postgresql` (namespace `clinvar`, database `clinvar`) — owns
  `clinvar_release`/`clinvar_variant_index`.
- `watchlist-postgresql` (namespace `watchlist`, database `watchlist`)
  — owns `subscriptions`/`deliveries`. Added 2026-08-09 (backlog #121):
  `watchlist-service` didn't exist when this runbook was first written,
  and the gap went unnoticed until a live PVC inventory for
  `flannel-restore.md` found it.

All three are single-instance Bitnami charts on a single node-pinned
`local-path` PVC each (ADR 0012/0019).

**Loki and Tempo are deliberately out of scope — decided, not an
oversight.** Both hold observability telemetry (logs, traces) that is a
byproduct of the system running, not data anyone created or that
anything else depends on for correctness. If either's PVC were lost, the
consequence is a gap in historical dashboards/trace lookups, not lost
work — the next request regenerates fresh logs and traces immediately.
That is a materially different risk than losing `work_items` or the
ClinVar release provenance, which have no regeneration path at all
(ClinVar's own upstream release could be re-ingested, but the local
`clinvar_release` history and specific indexed state would not match
what existed before). Backing them up would be spending real effort
protecting data that isn't worth protecting for this project. Not
addressed further here.

## Decision: mechanism

A daily `pg_dump` `CronJob` per instance, each writing to its own
**second, separate** `local-path` PVC (`kubernetes/postgresql-backup/`,
`kubernetes/clinvar-postgresql-backup/`) — deliberately not the same PVC
the database's own data lives on, so the backup doesn't share a single
point of failure with the thing it protects (see "What this does not
cover" below for the one failure mode that still defeats this: both PVCs
are on the same physical disk).

The Bitnami `postgresql` chart (pinned `16.2.1`, both instances) does
ship its own backup CronJob support — checked first via `helm show
values bitnami/postgresql --version 16.2.1` rather than assumed, per this
project's own established discipline (e.g. the registry-swap comment in
`argocd/apps/postgresql.yaml`). `backup.enabled: true` renders a `<name>
-pgdumpall` CronJob with its own PVC (`backup.cronjob.storage`, default
8Gi) — structurally the same shape this item asks for. It was not used,
for a concrete, verified reason:

**The chart's built-in CronJob authenticates as the `postgres` superuser**
(`PGUSER=postgres`, `PGPASSWORD` from the existingSecret's
`postgres-password` key) **and runs `pg_dumpall`.** Checking that
credential live against both instances (2026-07-30, read-only —
`psql -U postgres`) found it does **not** authenticate against api's
`postgresql`: `password authentication failed for user "postgres"`.

**Correction, found investigating this further (2026-07-30)**: this is
*not* a recurrence of platform#34/#36's Secret-drift class of bug. That
bug's signature is the Secret's value disagreeing with the live
container's own env var — checked directly here and they **agree**
(`kubectl get secret postgresql -n api -o jsonpath='{.data.postgres-password}'`
matches the pod's own `POSTGRES_POSTGRES_PASSWORD` exactly). The real
finding is different and, on a home-lab cluster with one operator, more
concerning in a quieter way: **the `postgres` role's actual password hash
stored inside PostgreSQL doesn't match either of those — a third, unknown
value** — most likely because `POSTGRES_POSTGRES_PASSWORD` is a
first-init-only setting (Bitnami's entrypoint only applies it while
`PGDATA` is being initialized, never on a later restart against existing
data), so whatever the Secret held *at that one moment* is what's live,
and it may never have matched what the Secret holds today, at any point.
Nothing has ever needed to authenticate as `postgres` in normal operation
(every real request goes through the least-privilege `api`/`clinvar` app
roles), so this has been silently true for an unknown amount of time
with no symptom, only surfacing now that this work tried to use the
superuser role for the first time. Tracked as backlog #73 rather than
fixed here — see that item for why (an `api`-role connection has no
privilege to `ALTER USER postgres`, so fixing this needs a real
`pg_hba.conf` trust-mode maintenance window, a bigger live-database
action than this backup work's own read-only scope covers).
(`clinvar-postgresql`'s `postgres` user does still authenticate
correctly today — only api's instance has this specific, currently
unexplained, latent gap.)

Fixing that credential is out of scope here and was **not** done as part
of this work — this item's own instructions are to only read from the
live instances, never modify them, and re-syncing a live superuser
password is exactly the kind of live-instance write that's excluded.
Rather than build a backup mechanism whose nightly success silently
depends on a credential known to be broken on at least one instance, the
CronJobs here use `pg_dump` (not `pg_dumpall`) authenticating as each
instance's existing **application** user (`api`/`clinvar`) — the same
credential each service already uses for every request, confirmed live
to work on both instances. This is also strictly the right scope: each
instance has exactly one database worth dumping, so `pg_dumpall`'s
whole-cluster/roles reach was never needed, and using the
already-least-privilege app credential instead of a superuser is a
strictly smaller blast radius for a backup job that doesn't need more.
Both CronJobs use the identical mechanism regardless of which instance's
`postgres` superuser happens to work today, rather than one depending on
a credential the other doesn't reliably have.

Concretely: `docker.io/bitnamilegacy/postgresql:17.1.0-debian-12-r0` (the
exact image already pinned for both instances, so `pg_dump`'s version
always matches the server) running `pg_dump --format=custom` daily
(`03:00`/`03:15`, staggered to avoid the single node's disk I/O
overlapping), 14 days' retention pruned by the job itself, writing into
the dedicated backup PVC. See `kubernetes/postgresql-backup/cronjob.yaml`
and `kubernetes/clinvar-postgresql-backup/cronjob.yaml` for the full
manifest and this reasoning inline.

## Restore procedure

1. Identify the dump to restore from the backup PVC (mount it via a
   throwaway pod, or `kubectl cp` a file out — the CronJob's container
   image has both `pg_dump`/`pg_restore` and the PVC is a normal
   `local-path` volume, nothing special-cased).
2. Stand up (or identify) the target Postgres instance and an empty
   destination database.
3. `pg_restore --no-owner --no-privileges -h <host> -U <user> -d
   <database> <dump file>`.
4. Verify row counts (and spot-check real rows) against what's expected
   before treating the restore as complete — never assume a
   zero-exit-code `pg_restore` alone proves data integrity.

## Real restore, proven live (2026-07-30)

Exercised for real against this project's actual live data, not a
synthetic fixture — read-only against the running `postgresql` and
`clinvar-postgresql` instances, restoring into new scratch resources
created and torn down for this exercise, per this item's own
instructions never to modify or delete anything in the live instances.

**1. Real dumps taken** (`pg_dump --format=custom`, executed inside each
live pod via `kubectl exec` as the existing app user, output copied out
via `kubectl cp`, then the in-pod scratch file removed — no write to
either instance's actual `PGDATA`):

| Instance | Database | Dump size |
|---|---|---|
| `postgresql` (api) | `api` | 4.4K |
| `clinvar-postgresql` | `clinvar` | 33M |

**2. Scratch restore target**: a throwaway `postgresql` Pod + its own
fresh `local-path` PVC in a dedicated, temporary namespace
(`backup-restore-verify`) — not the live `postgresql`/`clinvar-postgresql`
Applications, no ArgoCD involvement, nothing tracked in git. Two empty
databases created (`api_restore`, `clinvar_restore`), then both dumps
restored with `pg_restore --no-owner --no-privileges`, timed individually
wall-clock:

| Restore | Elapsed (measured) |
|---|---|
| `api` → `api_restore` (15 rows) | **0.31s** |
| `clinvar` → `clinvar_restore` (2,895,514 rows) | **46.4s** |

This is the real, measured RTO for this project's actual current data
volume — not an estimate. (Time to *produce* a fresh dump is a separate,
nightly-cadence number governed by the CronJob's own schedule, not part
of restoring from an already-existing backup file, which is what RTO
means here.)

**3. Row counts verified to match exactly**, source (live, read-only
query) vs. restored (scratch instance):

| Table | Live source | Restored |
|---|---|---|
| `work_items` | 15 | 15 |
| `clinvar_variant_index` | 2,895,514 | 2,895,514 |
| `clinvar_release` | 4 | 4 |

A specific known row was also spot-checked for content, not just count —
`rs80357906` (BRCA1, the same variant ADR 0018/backlog #24's integration
test asserts against) — identical `chrom`/`pos`/`ref`/`alt` in both the
live source and the restored scratch database.

**4. Cleanup confirmed**: the scratch pod, its PVC, and the temporary
namespace were all deleted after verification. The live `postgresql-0`
and `clinvar-postgresql-0` pods' restart counts and PVCs were checked
before and after and are unchanged — nothing about the live instances was
touched.

## `watchlist-postgresql`, proven live (2026-08-09, backlog #121)

Same exercise, same discipline, for the third instance added to this
runbook's scope above. The CronJob (`watchlist-postgresql-backup`,
platform#146) was triggered manually
(`kubectl create job --from=cronjob/watchlist-postgresql-backup`)
rather than waiting for its real 03:40 schedule, producing a real
7,478-byte `pg_dump` in ~seconds. Copied out via a temporary pod
mounting the backup PVC — this time matching the target's real
`runAsUser`/`runAsGroup` (1001/1001) from the start, the direct lesson
`flannel-restore.md` records from the same day's earlier `fsGroup`
incident, rather than a generic default `busybox` pod.

Restored into a scratch Postgres instance (`bitnamilegacy/postgresql:
17.1.0-debian-12-r0`, matching the pinned server version, same as the
other two) in a throwaway namespace (`backup-restore-verify`), via
`pg_restore --no-owner --no-privileges`. Row counts verified to match
the live source exactly, across all three real tables:

| Table | Live source | Restored |
|---|---|---|
| `subscriptions` | 0 | 0 |
| `deliveries` | 0 | 0 |
| `flyway_schema_history` | 1 | 1 |

Both `subscriptions` and `deliveries` are genuinely empty in this
instance's real current state — not a weaker proof by choice, just
this service's actual data volume today. Schema and constraints
(primary keys, the `deliveries_subscription_id_fkey` foreign key, the
`subscriptions_target_xor` check constraint) all restored correctly,
confirmed by the restore completing without a schema-level error on a
clean target.

**Real, isolated RTO measured: 0.308s** — timed around `pg_restore`
alone, after dropping and recreating the scratch schema to exclude an
earlier, non-isolated first attempt's timing from the number.

**Cleanup confirmed**: the scratch namespace (and everything in it),
the temporary read pod, and the manual test Job were all deleted after
verification. The live `watchlist-postgresql-0`/`watchlist-service`
pods' restart counts were checked before and after and are unchanged
(`0`, `8d`) — nothing about the live instance was touched.

## What this does not cover — accepted risk

**Single node/disk loss is an accepted risk this backup does not protect
against**, for a personal single-node project. This is not a new,
undiscussed assumption made here — it's the same acceptance already on
record in ADR 0021/S7 and backlog #23b (merged into this item): a
dedicated node-loss game day is ceremony on a single-node cluster where
killing the node is just killing everything, including both the primary
PVC and this item's own backup PVC (`local-path` is node-pinned, and both
PVCs currently land on the same physical disk on the one node this
cluster has). The restore drilled above proves the mechanism and gives a
real RTO; it does not simulate surviving that specific node's hardware
failing, because nothing on this cluster could survive that today, backup
included. The moment this matters again is a real multi-node migration
(roadmap M7) — off-node/off-disk backup replication is a fresh decision
for whatever storage substrate that migration lands on, not something to
half-build speculatively now.

## What this doesn't otherwise cover

- Point-in-time recovery (WAL archiving/continuous replication) — these
  are periodic logical dumps, so recovery is only ever to the last
  completed dump's point in time (up to ~24h of loss at worst), not to
  an arbitrary moment. Acceptable for this project's actual stakes per
  backlog #23a's own acceptance criteria.
- Automated restore drills on a schedule — this was a proven, one-time,
  real exercise (per backlog #23a's acceptance criteria), not a
  recurring game-day. A future repeat is a fine ad-hoc exercise, not a
  committed deliverable.
