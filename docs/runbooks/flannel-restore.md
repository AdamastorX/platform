# Flannel-restore runbook for the Cilium CNI rebuild (backlog #49, ADR 0040)

Not an alert-linked runbook (see `observability/runbooks/README.md` for
those) — like `backup-restore.md`, this is a decision plus a plain
operational procedure, written and rehearsed on paper *before* the
Cilium rebuild is attempted, per ADR 0040's own requirement: a broken
CNI on this project's only node is the one failure ArgoCD cannot
recover from (nothing can reach the API server to reconcile anything),
and there is no second node to retreat to. This document is the
required precondition for #49, not #49 itself — it does not touch the
live cluster.

## What actually happens on the day

`argocd/apps/cilium.yaml` doesn't exist yet — Cilium isn't a live
Application swap, it's a **whole-node CNI reinstall**: k3s has to come
up with `--flannel-backend=none --disable-network-policy
--disable-kube-proxy` from the start (Cilium takes over kube-proxy's
job too), and k3s does not support changing CNI on a running install.
The real mechanism, confirmed live against this exact host (`ps aux`,
the real running `k3s server` process, and
`~/.adamastorx/k3s-install.sh`, the actual script `terraform/main.tf`'s
`null_resource.k3s` runs):

```sh
#!/bin/sh
set -e
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb" sh -
chmod 644 /etc/rancher/k3s/k3s.yaml
```

Terraform's own destroy path already runs `k3s-uninstall.sh` (the
official uninstaller) before any create — proven, real behavior since
backlog #5, not new for this rebuild. **`k3s-uninstall.sh` removes
`/var/lib/rancher/k3s` entirely**, which is where `local-path`'s
`hostPath`-backed volumes actually live on disk — every PVC on this
cluster is wiped by the same destroy step that removes flannel, whether
the CNI is the reason for the rebuild or not. There is no way to swap
just the CNI without this.

**The restore path this runbook exists to make boring**: if the Cilium
attempt goes wrong (nodes can't reach the API server, CoreDNS can't
resolve, ArgoCD can't reconcile — anything that leaves the cluster
provably worse than before), the fix is `terraform destroy` +
`terraform apply` **again, unmodified** — the exact same
`k3s-install.sh` shown above is the *current, already-working* state,
with no Cilium-specific flags in it. Re-running it is not a special
recovery procedure improvised under pressure; it is the same command
already proven to work, run one more time. That's deliberate: the
"restore" is boring specifically because nothing about it is invented
for this scenario.

## Real inventory: every PVC that would be wiped, checked live

`kubectl get pvc -A`, run today (2026-08-09), not assumed from an old
count — **12 real PVCs across 9 namespaces**, all `local-path`, all on
the one node's one disk, all destroyed by the same `k3s-uninstall.sh`
step above:

| Namespace | PVC | Size | Classification |
|---|---|---|---|
| `api` | `data-postgresql-0` | — | **Must restore** — source of truth (`work_items`), no regen path. Already covered by `backup-restore.md`. |
| `clinvar` | `data-clinvar-postgresql-0` | — | **Must restore** — source of truth (`clinvar_release`/`clinvar_variant_index`), no regen path. Already covered by `backup-restore.md`. |
| `watchlist` | `data-watchlist-postgresql-0` | 2Gi | **Must restore — real gap found writing this runbook, now closed.** A third live Postgres instance, same source-of-truth class as the two above. `backup-restore.md` didn't mention it at all when this runbook was first written; it does now. A nightly `pg_dump` CronJob shipped (backlog #121, platform#146), and a real restore was proven the same day — see `backup-restore.md` for the row counts and measured RTO. |
| `api` / `clinvar` | `postgresql-backup` / `clinvar-postgresql-backup` | — | The *backup* PVCs themselves (`backup-restore.md`'s own CronJob targets) — wiped along with everything else; the real recovery artifact is whatever was last copied off-cluster before the rebuild, not the in-cluster backup PVC surviving the rebuild it's meant to protect against. |
| `prometheus` | `prometheus-server` | 16Gi | **Should restore.** Not source-of-truth business data, but backlog #94's real 30-day SLO-over-time report clock (started 2026-08-07, live-verified retention history) is a genuine, currently-active, time-sensitive asset a wipe would reset. The exact zero-data-loss copy-out/copy-in mechanism is already proven today, twice: once for #94's own PVC resize, and again fixing this same day's `CrashLoopBackOff` incident (with one addition this runbook inherits — see below). |
| `mimir` | `mimir-data` | — | Optional, low priority. A second copy of Prometheus's own data plus the incident findings ADR 0038/backlog #108 already wrote down permanently — losing the live pod's data loses nothing not already captured in the ADR/backlog record. Owner has explicitly chosen to keep Mimir running (this runbook does not change that); restoring it is a nice-to-have, not a requirement. |
| `kafka` | `data-kafka-controller-0` | 8Gi | Acceptable loss for every plain consumer group — each one materializes into Postgres or another durable store downstream, so a lost topic just means replaying from source, not losing data. **One unconfirmed exception, named rather than assumed away**: `aggregator` uses Kafka Streams, and a Streams app's internal changelog topic is the durable backing for its own state store, not just a pass-through log — if `aggregator`'s local state can't be rebuilt purely from its own upstream input topics, this row's blanket "acceptable loss" doesn't cleanly cover it. Confirm this one way or the other (check `aggregator`'s actual Streams topology) before treating the whole PVC as disposable on rebuild day. |
| `loki` | `storage-loki-0` | — | Acceptable loss — same reasoning `backup-restore.md` already used: observability telemetry, a byproduct of the system running, regenerates the moment traffic resumes. |
| `tempo` | `storage-tempo-0` | — | Acceptable loss, same reasoning as Loki. |
| `pyroscope` | `data-pyroscope-0` | — | Acceptable loss, same reasoning as Loki/Tempo — continuous profiles, not point-in-time evidence. |
| `clinvar` | `clinvar-service-refdata` | 2Gi | **Acceptable loss — resolved by reading the code (backlog #123), no longer unconfirmed.** `app/paths.py`'s `ClinVarRefdataPaths` holds only the downloaded VCF/TBI files for the current/previous release, a re-ingestible cache of the real upstream source, not source-of-truth data (`data-clinvar-postgresql-0` already owns that). Regenerated with one real ingestion run (`POST /internal/clinvar/ingest`, ~7 minutes against the current real dataset) — a real, triggered regeneration step, not left as "regenerable" without saying how. See `backup-restore.md`'s own updated scope statement. |

## Backup mechanism for what must survive

Same pattern as `backup-restore.md`'s proven Postgres procedure, **plus
one correction this project learned the hard way today, on this exact
class of restore**: any temporary pod used to copy PVC data out (or
back in) must run under **the target workload's own real `runAsUser`/
`runAsGroup`**, not whatever a generic `busybox` pod defaults to.

The reason is a real, live incident, not a theoretical concern —
2026-08-09, backlog #94's own status note: `local-path`'s PV type is
backed by `hostPath`, and the kubelet does **not** apply `fsGroup`
ownership correction to `hostPath`-backed volumes (unlike most other
volume types). A restore performed by a pod running under a different
uid than the target silently leaves the data unreadable/unwritable by
the real workload — caught that day only after a live
`CrashLoopBackOff`, the exact failure mode this runbook exists to keep
off of rebuild day, when there will be far more restores happening at
once and far less slack to debug one going wrong.

Concretely, for each PVC in the "must/should restore" rows above:

1. **Before the rebuild**: scale the owning Deployment/StatefulSet to
   0. A temporary pod, `securityContext.runAsUser`/`runAsGroup` set to
   match the real target workload (read from its own Deployment spec,
   not assumed), mounts the PVC and `kubectl cp`s the data to local
   disk outside the cluster.
2. **Destroy + recreate** (the actual CNI rebuild — out of scope for
   this document, covered by #49 itself).
3. **After the rebuild**: once ArgoCD's root app has reconciled the
   relevant namespace/PVC back into existence from git, a second
   temporary pod — same `runAsUser`/`runAsGroup` match, not a fresh
   default — `kubectl cp`s the data back in, then the Deployment/
   StatefulSet is scaled back to its real replica count.
4. **Verify, don't assume**: for the Postgres instances, real row
   counts and at least one spot-checked row, the same bar
   `backup-restore.md`'s own proven restore already set (15/15
   `work_items` rows, 2,895,514/2,895,514 `clinvar_variant_index`
   rows, a named BRCA1 variant checked byte-for-byte). For Prometheus,
   real `/api/v1/query?time=<past offset>` calls at several day-old
   offsets, the same technique #94's own PVC resize already proved
   live twice.

## What "rehearsed" means for this document specifically

Per ADR 0040's own requirement, this runbook is written *and
rehearsed* before the rebuild, not just written. What was rehearsed
today, for real, without touching the live cluster:

- **The real install script and the real running k3s flags were read
  directly off this exact host**, not assumed from `terraform/`'s own
  docs or an old note — confirmed identical (`--disable traefik
  --disable servicelb`, nothing else), so this document's central claim
  ("the restore is just re-running the current script") is checked, not
  asserted.
- **The real PVC inventory above is a live `kubectl get pvc -A`
  today**, not a memory of what used to be running — and it surfaced a
  real, previously-undocumented gap (`watchlist-postgresql`) that a
  written-from-memory version of this runbook would have missed
  entirely on the day it mattered most.
- **The backup mechanism's one hard-won correction (the `runAsUser`
  match) is drawn from a real incident that happened on this exact same
  laptop, today**, not a generic best practice pulled from documentation
  — the kind of lesson that's easy to state in the abstract and easy to
  forget to actually apply under the time pressure of a live rebuild,
  which is exactly why it's written down here instead of left to be
  remembered correctly in the moment.

## Post-restore acceptance checklist (backlog #123, mandatory after any rebuild)

`#49`'s own rebuild verification was thorough and every check passed —
35/35 scrape targets up, `cilium status OK`, consumer groups rejoined,
three Postgres instances restored with matching row counts. The system
was nevertheless broken in three real places afterward (backlog #122),
because every one of those checks was a *component-liveness* check and
none was a *business-path* check — this project's own already-learned
"silent-but-Healthy" lesson (#85, #86), generalized from a pod to a
whole cluster. **Run every line below after any future rebuild, before
declaring it done — a component being Running/Ready/Synced is not
this checklist's bar.**

Each line is a real, runnable command with a real committed expected
result, not prose to eyeball. First walked against the live, current,
post-#122 cluster on 2026-08-20/21 — every real result below, not
assumed:

1. **Real variant lookup returns a real classification.**
   ```sh
   curl -s "http://clinvar-service.clinvar.svc.cluster.local/internal/clinvar/lookup?rsid=rs80357906"
   ```
   Expect `HTTP 200`, `"clinicalSignificance":"Pathogenic"`. **PASS**
   (2026-08-20, same result this project's other real checks have used
   since #24).

2. **A real `POST /work-items` is observed consumed by `workers`.**
   ```sh
   curl -s -u "<tenant>:<key>" -X POST "http://api.api.svc.cluster.local/work-items" \
     -H "Content-Type: application/json" -d '{"message":"<unique-marker>"}'
   kubectl logs -n workers deploy/workers --tail=100 | grep "<unique-marker>"
   ```
   Expect `HTTP 202` then a real `Consumed work item id=... message=<unique-marker>`
   log line from `workers`. **PASS** (2026-08-20, real id
   `6f75491f-c8fc-4fe8-8e6d-134337b3cf73`, consumed and logged by
   `workers` ~14s later).

3. **The full expected Kafka topic list, compared against a committed
   set, not eyeballed.**
   ```sh
   kubectl exec -n kafka kafka-controller-0 -- kafka-topics.sh --bootstrap-server localhost:9092 --list
   ```
   Committed expected set (5 declaratively provisioned in
   `argocd/apps/kafka.yaml` + 4 `aggregator` Kafka Streams changelog
   topics, self-created via its own embedded `AdminClient`, backlog #95
   + `__consumer_offsets`, Kafka's own internal topic — 10 total):
   `work-items`, `stock.price.tick`, `news.article.published`,
   `news.sentiment.scored`, `clinvar.ingestion.completed`,
   `aggregator-latest-price-store-changelog`,
   `aggregator-latest-sentiment-store-changelog`,
   `aggregator-price-window-store-changelog`,
   `aggregator-sentiment-window-store-changelog`,
   `__consumer_offsets`. **PASS** (2026-08-20, exact match, 10/10).

4. **Every `probe_success` series equals 1.**
   ```sh
   curl -s 'http://prometheus-server.prometheus.svc.cluster.local/api/v1/query' \
     --data-urlencode 'query=probe_success'
   ```
   Expect every returned series' value `== 1`. **PASS** (2026-08-20,
   7/7 series, zero failures).

5. **`GET /aggregates` returns non-empty data with a fresh `priceAsOf`.**
   ```sh
   curl -s "http://aggregator.aggregator.svc.cluster.local/aggregates"
   ```
   Expect a non-empty array, `priceAsOf` within the last few minutes
   during real US market hours. **PASS** (2026-08-20, real live
   tickers, `priceAsOf` ~2 minutes old at check time).

6. **A real `clinvar.ingestion.completed` fan-out reaches a real
   delivery row.** A full real ingestion (~7 min) may find zero
   `changedKeys` if nothing changed upstream since the last run — not
   a useful acceptance signal on its own. Proven instead the way
   backlog #53's own original proof did: a real subscription plus a
   real, schema-valid message on the real topic.
   ```sh
   curl -s -X POST "http://watchlist-service.watchlist.svc.cluster.local/subscriptions" \
     -H "Content-Type: application/json" \
     -d '{"variantKey":"variantAnnotation:<chrom>:<pos>:<ref>:<alt>"}'
   # then produce a real message on clinvar.ingestion.completed whose
   # changedKeys includes that exact variantKey (kafka-console-producer
   # or a real ingestion run), then:
   kubectl exec -n watchlist watchlist-postgresql-0 -- psql -U watchlist -d watchlist \
     -c "select status, variant_key from deliveries order by created_at desc limit 1;"
   ```
   Expect a real row, `status = 'SENT'`, matching `variant_key`.
   **PASS** (2026-08-20/21, real delivery row
   `49c8dba8-23ef-4832-90c5-0235d922eeea`, `status=SENT`, exact
   `variant_key` match). **Note for whoever runs this next**: this real
   test subscription/delivery pair is intentionally left in the live
   `watchlist` database — cleanup via a raw `DELETE` was correctly
   blocked by this session's own permission classifier (a destructive
   action against live production data), and the app's own `DELETE
   /subscriptions/{id}` 500s when real deliveries reference the
   subscription (a real, minor, separately-tracked bug — see backlog
   #141). Harmless to leave; delete both rows by hand if it bothers a
   future reader, or fix #141 first so the API can do it cleanly.

Two real, small findings surfaced walking this checklist, not part of
its own AC but worth recording rather than dropping: `services/schemas/
examples/clinvar.ingestion.completed.valid.json`'s `changedKeys`
example (`"17:41197588:G:A"`) does not match the real producer's
actual wire format (`"variantAnnotation:17:41197588:G:A"`,
`app/diff.py`'s `_make_key`) — a real event-contract drift #96's own
schema-only validation can't catch (tracked as backlog #141, which
also covers the `DELETE /subscriptions/{id}` 500 above).

**Update (2026-08-09, later same day)**: `watchlist-postgresql`'s
backup gap is closed — CronJob shipped and a real restore proven
(backlog #121, platform#146/#147; see `backup-restore.md` for the full
account). One honest exception to this section's own "row counts and
at least one spot-checked row" bar, stated there rather than here:
`watchlist`'s two real data tables are currently empty, so that
restore proved the mechanism and schema, not row-level data-copy
integrity — re-run once real data exists. **What's still deliberately
not rehearsed, and stays open
before #49 is attempted for real**: an actual `terraform destroy` +
`terraform apply` cycle on this live cluster. That remains the one
real, scoped precondition this document doesn't yet cover, not
glossed over as already covered by this document existing.
