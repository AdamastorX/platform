# bootstrap

One-time cluster bootstrap: installing ArgoCD itself, provisioning the
Secrets that stateful charts can no longer generate for themselves, and
handing the cluster over to GitOps. This is the **only** place where
manual `kubectl apply`/`kubectl create` against a real environment is
sanctioned — it is pre-GitOps by definition (something has to install the
GitOps engine and seed the credentials it will read but never create).
After bootstrap, every cluster change flows through Git via the root
Application.

## What gets installed

| What | Value |
|---|---|
| ArgoCD version | **v3.4.5** (pinned) |
| Install method | Official upstream install manifests, **non-HA** |
| Manifest URL | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml` |
| Namespace | `argocd` |
| Entrypoint | `root-app.yaml` — the app-of-apps root (see [`../argocd/README.md`](../argocd/README.md)) |

**Why non-HA install manifests:** single-node k3s cluster — HA would be gold
plating. **Why raw manifests over the Helm chart:** the upstream install.yaml
pinned to a version tag is the smallest, most boring option; there is nothing
to templatize yet. If ArgoCD ever needs real configuration, revisit (that
would be a values-managed Helm install, self-managed by ArgoCD).

## Stateful-service Secrets (postgresql / redis / clinvar-postgresql / kafka)

platform#36 migrated these 4 Bitnami charts off chart-generated passwords
(root fix for platform#34's Secret-regeneration bug) onto a pre-created
Secret each chart reads via `auth.existingSecret` / `existingKraftSecret`
but never creates itself. See `create-stateful-secrets.sh`'s header
comment for the full plaintext-in-git-vs-sealed-secrets-vs-out-of-band
tradeoff writeup — the short version: this is a public repo, so a
plaintext Secret manifest doesn't get committed to git, and a new
sealed-secrets/SOPS dependency wasn't justified for 4 low-stakes
credentials on a personal single-node cluster. Instead, `install-argocd.sh`
runs `create-stateful-secrets.sh` as a second sanctioned manual step,
before `root-app.yaml` ever lets ArgoCD sync these Applications for the
first time — those charts can no longer generate their own Secret, so it
has to already exist by the time the first sync creates a
Deployment/pod reading it via `secretKeyRef`. The script is idempotent
(skips any Secret that already exists), so it's safe to re-run against
an already-bootstrapped cluster without disturbing a running
Postgres/Redis/Kafka's actual credentials.

## Per-tenant API keys (backlog #56)

The same script also provisions the Secrets backing api's edge auth
(`kubernetes/api/middlewares.yaml`'s `api-key-auth`/`api-key-ratelimit`
Traefik middleware): `api-tenant-keys` (api namespace, the htpasswd file
Traefik itself reads), `workload-generator-api-key` (workload-generator
namespace) and `clinvar-viewer-api-key` (clinvar-viewer namespace, holding
a ready-to-mount `config.js`) -- one raw key generated once per tenant and
reused to seed all three, so every real caller's key is exactly what
Traefik will accept. Also creates an `adamastorx-ca` ConfigMap in the
workload-generator namespace, mirroring the cluster's private CA root
(cert-manager namespace's `adamastorx-root-ca` Secret) so that pod can
verify api's Ingress certificate now that it calls it by public hostname
instead of in-cluster Service DNS.

Same idempotency rule as the stateful Secrets above: if `api-tenant-keys`
already exists, the whole block is skipped (deliberately -- see the
script's own comment for why a partial re-run can't safely recover a raw
key from an existing htpasswd hash).

## Finnhub API key (backlog #78)

`market-data-ingestor` (ADR 0029/M13) reads a real Finnhub free-tier API
key from the `finnhub-api-key` Secret (`market-data-ingestor` namespace,
`api-key` key) via `secretKeyRef` -- **not created by
`create-stateful-secrets.sh`**, unlike every other Secret this directory
provisions. It's a real third-party vendor credential (a human's Finnhub
account), not something `gen_password`/`gen_api_key` can generate
locally. Create it by hand:

```sh
kubectl create secret generic finnhub-api-key -n market-data-ingestor \
  --from-literal=api-key=<the real key from your finnhub.io account>
```

Already provisioned on this cluster (created and live-verified against a
real `https://finnhub.io/api/v1/quote` call before backlog #78's PR was
opened). `create-stateful-secrets.sh` still creates the
`market-data-ingestor` namespace and checks whether this Secret exists,
printing the command above if it's missing -- the same "documented, not
silently assumed" bar every other Secret here meets, short of actually
generating a value it has no way to generate.

**Rotating an api-tenant-keys key**: not yet automated. Delete the four
Secrets (`api-tenant-keys`, `workload-generator-api-key`,
`clinvar-viewer-api-key`, and re-run the script) and roll the two
consuming Deployments (`kubectl rollout restart`) so they pick up the new
value -- `workload-generator`'s env var and `clinvar-viewer`'s mounted
`config.js` are both read at pod start, not live-reloaded the way
`workload-generator-config`'s rate ConfigMap is.

## visualizer's config.js (backlog #82)

Same "no backend of its own, so the Secret's payload is the literal
`config.js` file" mechanism as `clinvar-viewer-api-key` above, extended
to also carry the API base URL: `visualizer-config` (`visualizer`
namespace) holds `window.ADAMASTORX_API_BASE = "https://aggregator.local.adamastorx.test";`
-- no `ADAMASTORX_API_KEY` line, because `aggregator`'s own Ingress
(`kubernetes/aggregator/ingress.yaml`) deliberately does not enable
backlog #56's api-key-auth middleware for this v1 (see that file's own
comment for the real, stated reasoning: exactly one real caller today,
unlike `api`'s multi-tenant situation). Idempotent like every Secret
above.

## ntfy alert topic (backlog #107)

`ntfy-webhook-url` (`prometheus` namespace) holds the full
`https://ntfy.sh/<topic>` URL Alertmanager's ntfy receiver posts to,
read via `url_file` (`argocd/apps/prometheus.yaml`'s
`alertmanager.extraSecretMounts`) rather than embedded in that
git-tracked, public file — real incident found 2026-08-06: the topic
name used to be committed there directly, defeating ntfy's own stated
"not being guessable" protection in the same file that stated it.
Idempotent like every Secret above, with the same one-time-visible
caveat `api-tenant-keys`' smoke-test key has: **subscribe the ntfy
app/website to the printed topic when this script creates it** —
ntfy topics carry no recoverable secret, only a name, and there is no
second chance to read it back after this step.

**Rotating the ntfy topic**: delete the `ntfy-webhook-url` Secret and
re-run this script (a fresh topic is generated); re-subscribe the ntfy
app/website to the new topic before the old one is decommissioned, or
alerts go silently unheard between the rotation and the resubscribe.

## Re-bootstrap from zero

Given a fresh k3s cluster (provisioned via `../terraform/`):

```sh
export KUBECONFIG=../terraform/kubeconfig
./install-argocd.sh
```

The script:

1. Creates the `argocd` namespace (idempotent).
2. Applies the pinned upstream install manifests.
3. Waits for all ArgoCD deployments to become Available.
4. Runs `create-stateful-secrets.sh` — creates the `api`/`clinvar`/`kafka`
   namespaces and the 4 pre-created Secrets those namespaces' charts read
   (idempotent; see the section above).
5. Applies `root-app.yaml` — the root app-of-apps Application pointing at
   this repo's `argocd/apps/` on `main`.

From that point, ArgoCD reconciles the cluster against `main` automatically
(selfHeal; prune is deliberately off for the 4 Applications above — see
their own `syncPolicy` comments). Adding or changing anything in the
cluster = a PR to this repo.

## Accessing the ArgoCD UI

Traefik and ServiceLB are intentionally disabled in this cluster (our own
Traefik lands later, issue platform#3), so there is no Ingress or
LoadBalancer. Use a port-forward:

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then browse https://localhost:8080 (self-signed cert)
```

Initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Upgrading ArgoCD

Bump `ARGOCD_VERSION` in `install-argocd.sh` and the version references in
this README via PR, then re-run the script (the upstream manifests apply
cleanly over an existing install). This is a bootstrap-tool upgrade, not a
workload change, so it is the same sanctioned exception.
