# bootstrap

One-time cluster bootstrap: installing ArgoCD itself and handing the cluster
over to GitOps. This is the **only** place where manual `kubectl apply`
against a real environment is sanctioned — it is pre-GitOps by definition
(something has to install the GitOps engine). After bootstrap, every cluster
change flows through Git via the root Application.

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
4. Applies `root-app.yaml` — the root app-of-apps Application pointing at
   this repo's `argocd/apps/` on `main`.

From that point, ArgoCD reconciles the cluster against `main` automatically
(prune + selfHeal). Adding or changing anything in the cluster = a PR to
this repo.

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
