# kubernetes

Raw manifests not warranting a full Helm chart. One directory per app;
each is deployed by a matching ArgoCD `Application` under
[`../argocd/apps/`](../argocd/apps/) — see [`../argocd/README.md`](../argocd/README.md).

| Dir | What |
|---|---|
| `whoami/` | Trivial GitOps proof app (`traefik/whoami` Deployment + ClusterIP Service + TLS Ingress) |
| `cert-manager-issuers/` | Project CA: self-signed bootstrap CA + `adamastorx-ca` ClusterIssuer (see its README for why not Let's Encrypt) |
