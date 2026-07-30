# kubernetes

Raw manifests not warranting a full Helm chart. One directory per app;
each is deployed by a matching ArgoCD `Application` under
[`../argocd/apps/`](../argocd/apps/) — see [`../argocd/README.md`](../argocd/README.md).

| Dir | What |
|---|---|
| `api/` | The one public application service; `ingress.yaml` + cert-manager Certificate is the live Traefik+TLS+service path (ADR 0021/backlog #S1) |
| `cert-manager-issuers/` | Project CA: self-signed bootstrap CA + `adamastorx-ca` ClusterIssuer (see its README for why not Let's Encrypt) |
| `postgresql-backup/` | Daily `pg_dump` CronJob + its own separate PVC for api's `postgresql` (backlog #23a — see `../docs/runbooks/backup-restore.md`) |
| `clinvar-postgresql-backup/` | Daily `pg_dump` CronJob + its own separate PVC for `clinvar-postgresql` (backlog #23a — see `../docs/runbooks/backup-restore.md`) |
