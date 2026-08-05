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
`Certificate`. See [`../api/ingress.yaml`](../api/ingress.yaml).

## Fixed local addresses, no more port-forward

`api`, `grafana`, `prometheus`, `alertmanager`, `clinvar-viewer`,
`aggregator`, `visualizer` (backlog #82, M13, ADR 0029), `pyroscope`
(backlog #57's real UI, no Ingress until now — port-forward only), and
`argocd` (the ArgoCD UI itself) each have a stable
`*.local.adamastorx.test` Ingress (Traefik, hostPort 80/443, ADR 0005).
ArgoCD's own `argocd-server` terminates its own TLS and 307-redirects
plain HTTP by default -- `server.insecure: "true"` (set in
`bootstrap/install-argocd.sh`) makes it serve plain HTTP internally
instead, so Traefik/cert-manager stays the single TLS termination point
for every service here, not just the GitOps-managed ones. None of this
resolves anywhere by default — it's not public DNS (see above), just a
hostname pattern. Two one-time steps make it actually work without a
manual `--resolve`/`--cacert` flag every time:

**`.test`, not `.dev`.** The first version of this used
`*.local.adamastorx.dev` — real, live-tested, and it broke in both
Chrome and Firefox with an unrecoverable HSTS error ("you cannot add an
exception"), even before the CA had been trusted anywhere. `.dev` is
Google-owned and HSTS-preloaded into every major browser unconditionally
— every `.dev` hostname is forced into strict-HTTPS-with-a-fully-trusted-
cert with **no manual override available at all**, unlike a normal
self-signed-cert warning. `.test` is IANA-reserved specifically for
non-public testing, never delegated, and not on any preload list —
confirmed live, no HSTS error, once the CA above is trusted.

**1. Resolve the hostnames.** Add one line per service to `/etc/hosts`
(the node's IP — update this if the cluster ever moves, e.g. to a
dedicated desktop host, per the roadmap note above):

```
192.168.1.10 api.local.adamastorx.test grafana.local.adamastorx.test prometheus.local.adamastorx.test alertmanager.local.adamastorx.test clinvar-viewer.local.adamastorx.test aggregator.local.adamastorx.test visualizer.local.adamastorx.test pyroscope.local.adamastorx.test argocd.local.adamastorx.test
```

**2. Trust the CA once**, instead of passing `--cacert adamastorx-ca.crt`
to every `curl`/browser. Three separate trust stores in practice, not
one — confirmed live, not assumed (Chrome/Chromium on Linux does *not*
read the system OpenSSL store `update-ca-certificates` populates; it
has its own NSS database):

```sh
kubectl get secret -n cert-manager adamastorx-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > adamastorx-ca.crt

# curl and most other Linux tools:
sudo cp adamastorx-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# Chrome/Chromium (its own NSS store, not the system one above):
sudo apt install libnss3-tools  # if not already present
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "adamastorx-ca" -i adamastorx-ca.crt
# then fully quit and reopen Chrome, not just the tab

# Firefox (its own store too): Settings → Privacy & Security →
# Certificates → View Certificates → Authorities → Import → adamastorx-ca.crt
```

After all three: `https://grafana.local.adamastorx.test` just works, in
any browser or `curl`, no flags.
