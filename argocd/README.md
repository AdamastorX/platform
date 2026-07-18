# argocd

ArgoCD Application definitions — the GitOps entrypoint. Everything running
in the cluster (beyond k3s itself and ArgoCD) is declared here.

## App-of-apps pattern

One **root** Application (`../bootstrap/root-app.yaml`, applied once during
bootstrap) watches this repo at path [`apps/`](apps/) on `main`. Every
manifest in `apps/` is itself an ArgoCD `Application` pointing at the actual
workload manifests (under `../kubernetes/` or `../helm/`). ArgoCD reconciles
the whole tree automatically:

```
bootstrap/root-app.yaml          (applied manually, once)
  └── argocd/apps/*.yaml         (one Application per app, added via PR)
        └── kubernetes/<app>/    (the app's actual manifests)
```

Both the root and child apps use automated sync with `prune: true` and
`selfHeal: true`: merged to `main` means deployed; deleted from `main`
means removed from the cluster; manual drift gets reverted.

## How to add a new app

1. Put the app's manifests under `../kubernetes/<name>/` (or a chart under
   `../helm/<name>/`).
2. Add `apps/<name>.yaml` — an `Application` with:
   - `metadata.namespace: argocd` and the resources finalizer
   - `spec.source`: this repo's URL, `targetRevision: main`, and the path
     from step 1
   - `spec.destination.namespace`: the app's target namespace, with
     `syncOptions: [CreateNamespace=true]` if it's a new one
   - automated sync policy (prune + selfHeal)
3. Open a PR. On merge, ArgoCD picks it up and deploys — no kubectl.

Use [`apps/whoami.yaml`](apps/whoami.yaml) as the template; it is the
minimal proof app from the bootstrap (a `traefik/whoami` Deployment +
ClusterIP Service under `../kubernetes/whoami/`).
