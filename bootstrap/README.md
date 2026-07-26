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
