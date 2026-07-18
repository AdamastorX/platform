# cert-manager-issuers

Cluster-wide certificate issuers, deployed by
[`../../argocd/apps/cert-manager-issuers.yaml`](../../argocd/apps/cert-manager-issuers.yaml).

## Why a self-signed CA and not Let's Encrypt

The cluster currently runs on a NATed machine with no public IP
reachability and no public DNS, so neither ACME challenge can complete:

- **HTTP-01** — Let's Encrypt must reach `http://<host>/.well-known/...`
  from the internet; it can't.
- **DNS-01** — needs real, publicly resolvable DNS records for the
  hostnames; there are none.

A Let's Encrypt `ClusterIssuer` here would just be permanently-failing
config pretending to work. Instead we use cert-manager's
[bootstrap-CA pattern](https://cert-manager.io/docs/configuration/selfsigned/#bootstrapping-ca-issuers):

```
selfsigned (ClusterIssuer)          signs, once
  └── adamastorx-root-ca (Certificate, 10y, isCA)
        └── adamastorx-ca (ClusterIssuer)   ← reference this one
```

Issuance and renewal are fully automatic and real — only trust is
project-local. Clients verify against the root in the
`adamastorx-root-ca` Secret (`cert-manager` namespace, `ca.crt` key):

```sh
kubectl get secret -n cert-manager adamastorx-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > adamastorx-ca.crt
curl --cacert adamastorx-ca.crt ...
```

**Follow-up:** when the cluster moves to a host with public DNS (already
on the roadmap), add a Let's Encrypt `ClusterIssuer` alongside this one
and switch Ingress annotations per-service. This CA can stay for
internal-only endpoints.

## Requesting a certificate

Annotate an Ingress with `cert-manager.io/cluster-issuer: adamastorx-ca`
and give it a `tls` section — ingress-shim creates and renews the
`Certificate`. See [`../whoami/ingress.yaml`](../whoami/ingress.yaml).
