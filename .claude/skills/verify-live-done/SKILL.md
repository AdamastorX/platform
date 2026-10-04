---
name: verify-live-done
description: Verify a change is actually live and working end-to-end before marking a backlog item Done, and re-walk the post-rebuild business-path acceptance checklist after any cluster rebuild (backlog #123, #49/flannel-restore). Use whenever about to mark something Done based on component-liveness signals alone (Running/Ready/Synced/scraped), after any k3s/Cilium rebuild, or when asked to "verify live" / "run the post-rebuild checklist". Encodes the 6 real business-path assertions, the Cilium toPorts-container-port trap, and the root-refresh-first ArgoCD gremlin — component-Healthy is not this Skill's bar.
---

# Verify-live-Done / post-rebuild acceptance

The project's own repeated, hard-learned lesson (#85, #86, generalized to
a whole cluster by #122/#123): **a component can be Running, Ready,
scraped, and Synced while the thing it exists to do does not work.**
`#49`'s rebuild verification was thorough and every component-liveness
check passed — 35/35 scrape targets up, `cilium status OK`, consumer
groups rejoined, three Postgres instances restored with matching row
counts — and the system was still broken in three real places
afterward (#122), because none of those checks was a *business-path*
check. This Skill is the corrective: run it before calling anything
Done on the strength of liveness signals alone, and mandatorily after
any future flannel/Cilium rebuild.

Full source: `platform/docs/runbooks/flannel-restore.md`'s "Post-restore
acceptance checklist" section (backlog #123).

## The two gotchas — check these before anything else

**1. Cilium `toPorts` needs the real backend *container* port, not the
Service's own port.** Cilium evaluates policy on the post-DNAT packet.
`clinvar-service`'s Service is port 80, its container listens on 8000 —
a `toPorts` rule naming port 80 lets nothing through even though the
Service "looks" reachable, and a manual connectivity test against the
wrong port causes a real false-alarm ("policy is broken" / "the rebuild
broke connectivity") when the policy was fine all along. **Before
concluding a policy is broken, or before writing a new `toPorts` rule**:

```bash
kubectl get svc -n <namespace> <service-name> -o jsonpath='{.spec.ports}'
```

Compare the Service port against the container's actual `containerPort`
(`kubectl get deploy/rollout -n <ns> <name> -o jsonpath='{.spec.template.spec.containers[0].ports}'`)
— they are frequently different, and the gap is invisible from `kubectl
get svc` alone.

**2. `root` needs its own refresh, not just the child Application's.**
`root` (the app-of-apps root Application, ADR 0003) manages every child
`Application` under `argocd/apps/` as one of its *own* tracked resources.
If `root` itself hasn't detected the git diff on a child's spec, hard-
refreshing the child alone just re-confirms it's "Synced" against the
**stale** spec `root` already gave it — this happens on a completely
normal git-merge path, not just a manual live patch. Symptom: `kubectl
get application <child> -n argocd -o json` shows old
`spec.source.helm.valuesObject` content even right after
`argocd.argoproj.io/refresh=hard` on the child, while `git log` confirms
the right commit is already on `main`.

```bash
# Check root itself, not the child, when a merged change isn't showing up live
kubectl get application root -n argocd -o jsonpath='{.status.sync.status}'
# If it's already "Synced" with a stale operationState.finishedAt, force it:
kubectl argocd app get root --refresh=hard   # or: annotate for refresh=hard
# THEN refresh the child, not before
```

Do the root refresh **first**, confirm `root` itself actually flips to a
real `OutOfSync` (not already `Synced`), let its own
`automated`+`selfHeal` sync fire, and only then refresh/inspect the
child. Refreshing the child first is the mistake that costs the ~10+
minutes this gremlin has already cost twice (backlog #100's ntfy-webhook
change, backlog #125's alert-rule change) — both independently rediscovered
the same shape before this was written down.

## The 6 business-path assertions

Every line below is a real, runnable, read-only command with a real
committed expected result — not prose to eyeball. Run every one after
any future rebuild, and any time "Done" is about to be declared on the
strength of liveness checks alone. All are read-only from the cluster's
perspective except assertion 2 (a real `POST /work-items`) and assertion
6 (a real subscription + a real Kafka message) — both create real,
harmless artifacts, same as the original 2026-08-20/21 run; that's
expected, not a mistake to avoid.

1. **Real variant lookup returns a real classification.**
   ```bash
   curl -s "http://clinvar-service.clinvar.svc.cluster.local/internal/clinvar/lookup?rsid=rs80357906"
   ```
   Expect `HTTP 200`, `"clinicalSignificance":"Pathogenic"`.

2. **A real `POST /work-items` is observed consumed by `workers`.**
   ```bash
   curl -s -u "<tenant>:<key>" -X POST "http://api.api.svc.cluster.local/work-items" \
     -H "Content-Type: application/json" -d '{"message":"<unique-marker>"}'
   kubectl logs -n workers deploy/workers --tail=100 | grep "<unique-marker>"
   ```
   Expect `HTTP 202` then a real `Consumed work item id=... message=<unique-marker>`
   log line from `workers`. `workers` scales via KEDA from 0
   (`cooldownPeriod: 120s`) — if the pod isn't up yet, wait for the scale-up
   and re-check quickly; a scaled-to-zero pod's own logs are gone once it's
   deleted, so check promptly after the POST rather than after the
   cooldown window closes.

3. **The full expected Kafka topic list, compared against a committed
   set, not eyeballed.**
   ```bash
   kubectl exec -n kafka kafka-controller-0 -- kafka-topics.sh --bootstrap-server localhost:9092 --list
   ```
   Committed expected set (10 total): `work-items`, `stock.price.tick`,
   `news.article.published`, `news.sentiment.scored`,
   `clinvar.ingestion.completed`, `aggregator-latest-price-store-changelog`,
   `aggregator-latest-sentiment-store-changelog`,
   `aggregator-price-window-store-changelog`,
   `aggregator-sentiment-window-store-changelog`, `__consumer_offsets`.

4. **Every `probe_success` series equals 1.**
   ```bash
   curl -s 'http://prometheus-server.prometheus.svc.cluster.local/api/v1/query' \
     --data-urlencode 'query=probe_success'
   ```
   Expect every returned series' value `== 1`.

5. **`GET /aggregates` returns non-empty data with a fresh `priceAsOf`.**
   ```bash
   curl -s "http://aggregator.aggregator.svc.cluster.local/aggregates"
   ```
   Expect a non-empty array, `priceAsOf` within the last few minutes
   during real US market hours (09:30-16:00 America/New_York). Outside
   market hours a slightly older `priceAsOf` from the last session is
   expected, not a failure.

6. **A real `clinvar.ingestion.completed` fan-out reaches a real
   delivery row.** Proven via a real subscription plus a real,
   schema-valid message on the real topic (a full ~7min re-ingestion
   could organically find zero `changedKeys` and isn't a useful signal
   on its own).
   ```bash
   curl -s -X POST "http://watchlist-service.watchlist.svc.cluster.local/subscriptions" \
     -H "Content-Type: application/json" \
     -d '{"variantKey":"variantAnnotation:<chrom>:<pos>:<ref>:<alt>"}'
   # then produce a real, schema-valid message on clinvar.ingestion.completed
   # whose changedKeys includes that exact variantKey:
   #   required fields: newReleaseId, previousReleaseId, publishedDate,
   #   variantCount, ingestedAt, changedKeys (backlog #141's pattern:
   #   "^variantAnnotation:[^:]+:[0-9]+:[^:]+:[^:]+$")
   kubectl exec -n watchlist watchlist-postgresql-0 -- psql -U watchlist -d watchlist \
     -c "select status, variant_key from deliveries order by created_at desc limit 5;"
   ```
   Expect a real row per matching live subscription, `status = 'SENT'`,
   exact `variant_key` match. More than one `SENT` row for the same
   message is expected, not a bug, if more than one live subscription
   shares that `variantKey` — fan-out is per-subscription.

## Network-access note (not a gotcha, just current topology)

Backlog #50/#126's default-deny `CiliumNetworkPolicy` batches mean not
every pod can reach every service directly — e.g. `api`'s own pod
cannot reach `prometheus-server` (no egress rule for that flow), and
`workload-generator` cannot reach `clinvar-service` or `api`'s internal
Service DNS directly (only through the public Ingress on its real
`API_BASE_URL`/`AUTH_USERNAME`+`API_KEY` path). When a curl from one
pod times out, try the same check as a self-loopback from the target's
own pod (`kubectl exec -n <ns> <target-pod> -- wget -qO- http://localhost:<port>/...`)
before concluding the endpoint itself is broken — this is a policy-shape
fact, not evidence of an outage, and re-deriving it each time wastes the
time this Skill exists to save.

## What "Done" requires

All 6 assertions **PASS**, recorded with real, dated results (not "should
work") in `flannel-restore.md`'s own checklist section for a post-rebuild
run, or in the closing backlog-item note for a Done-verification run.
Any assertion that fails or can't be run is a real, named gap — write it
down (as backlog #123's own closure did for the two small bugs it found:
the `clinvar.ingestion.completed` schema-example drift and the
`DELETE /subscriptions/{id}` 500, both tracked as #141) rather than
silently retried until it passes or quietly dropped from the checklist.
