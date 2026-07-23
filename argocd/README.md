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

## Current apps

| App | Source | What |
|---|---|---|
| [`whoami`](apps/whoami.yaml) | `../kubernetes/whoami/` | GitOps proof app; also the TLS-through-Traefik proof (Ingress + cert from `adamastorx-ca`) |
| [`traefik`](apps/traefik.yaml) | Helm chart `traefik` 41.0.2 | Ingress controller (k3s's bundled one is disabled) |
| [`cert-manager`](apps/cert-manager.yaml) | Helm chart `cert-manager` v1.21.0 | Certificate issuance/renewal operator |
| [`cert-manager-issuers`](apps/cert-manager-issuers.yaml) | `../kubernetes/cert-manager-issuers/` | Project CA: self-signed bootstrap CA + `adamastorx-ca` ClusterIssuer |
| [`kafka`](apps/kafka.yaml) | Helm chart `kafka` 32.4.3 | Single-broker KRaft messaging (ADR 0011); broker + `work-items` topic only, `workers` consumer deploys separately |

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

Third-party components install straight from their official Helm repos:
`spec.source` uses the chart repo URL, `chart:`, a **pinned**
`targetRevision`, and inline `helm.valuesObject` (a separate values file
only once values outgrow the manifest). Add
`syncOptions: [ServerSideApply=true]` when the chart ships large CRDs —
client-side apply dies past 256KB of last-applied-configuration
annotation (cert-manager's CRDs do, Traefik's get close).

## Non-obvious config choices

### traefik

- **hostPort 80/443, ClusterIP Service** — k3s runs with
  `--disable servicelb` and there's no cloud LB, so `type: LoadBalancer`
  would stay `<pending>` forever. On a single node with 80/443 free,
  hostPort gives real ports with zero extra moving parts (vs NodePort's
  `:3xxxx`). Revisit when the cluster has more than one node.
- **`updateStrategy` maxSurge=0** — a surge pod can't bind an
  already-bound hostPort on the only node; the default strategy would
  deadlock every Traefik upgrade.
- **`ingressEndpoint.ip`** (node IP) instead of `publishedService` — the
  published Service is ClusterIP and has no LB status to copy, which
  would leave every Ingress `.status` empty and its ArgoCD app stuck
  Progressing. The IP is cosmetic status data only; actual traffic hits
  the hostPort on whatever IP the node has.

### cert-manager

- **No Let's Encrypt (yet)** — the host is NATed with no public DNS, so
  ACME can't complete; certificates come from a project-local CA instead.
  Full rationale and the Let's Encrypt follow-up plan:
  [`../kubernetes/cert-manager-issuers/README.md`](../kubernetes/cert-manager-issuers/README.md).
- **Issuers in their own app** — cert-manager CRs can only sync once the
  operator's CRDs and webhook are live; the separate app retries through
  that window instead of holding the operator install hostage.

### kafka

- **Broker only, this PR** — the `work-items` topic is provisioned here too
  (chart's built-in `provisioning` Job), but the `workers` consumer service
  is a separate deploy once its image is published, mirroring how
  gateway/api followed their own scaffold PRs.
- **`docker.io/bitnamilegacy/kafka` image, not the chart's default
  `docker.io/bitnami/kafka`** — Bitnami stopped publishing versioned tags
  to the free `docker.io/bitnami/*` catalog in Aug 2025 (Bitnami Secure
  Images transition); the chart's own default tag 404s. `bitnamilegacy`
  still hosts that exact tag, **frozen with no further updates** — accepted
  for a dev-only broker nothing external reaches, but worth a second look
  if this ever needs to move past Kafka 4.0.0.
- **PLAINTEXT listeners, not the chart default `SASL_PLAINTEXT`** — Kafka
  is ClusterIP-only and nothing outside the cluster ever reaches it; same
  no-auth-between-in-cluster-services trust model gateway/api already use
  (ADR 0010). Avoids standing up Secret-based SASL credential rotation for
  a broker with no external attack surface.
- **`persistence.enabled: false` (emptyDir), not a PVC** — ADR 0011
  explicitly accepts topic data loss on broker restart at this stage;
  emptyDir needs no StorageClass and matches "simplest option that fits."
- **Single combined controller+broker node** (`controller.replicaCount: 1`,
  `broker.replicaCount: 0`) — KRaft with no ZooKeeper, per ADR 0011.
  Reachable in-cluster at `kafka.kafka.svc.cluster.local:9092`.
