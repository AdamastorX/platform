# terraform

Provisions k3s on `var.target_host` (default: this machine, `127.0.0.1`) over
SSH. Traefik and ServiceLB are disabled at install — this project brings its
own Traefik + cert-manager (see `platform/argocd/`).

## One-time host prep (not managed by Terraform)

Terraform needs passwordless SSH + narrowly-scoped passwordless sudo on the
target host, done once, by hand, before `terraform apply`:

1. `openssh-server` installed and running, bound to `127.0.0.1` if the target
   is this machine (`/etc/ssh/sshd_config.d/localhost-only.conf`:
   `ListenAddress 127.0.0.1`).
2. Terraform's SSH key in `~/.ssh/authorized_keys` on the target.
3. The install script at `~/.adamastorx/k3s-install.sh` on the target
   (installs k3s, disables traefik/servicelb, opens up kubeconfig
   permissions — see the script itself).
4. A sudoers drop-in scoping NOPASSWD to exactly those two scripts, nothing
   else:
   ```
   # /etc/sudoers.d/adamastorx-k3s
   <user> ALL=(root) NOPASSWD: /home/<user>/.adamastorx/k3s-install.sh, /usr/local/bin/k3s-uninstall.sh
   ```
   Always validate with `visudo -c -f <file>` before installing it and
   `visudo -c` after — a bad sudoers file can lock out sudo entirely.

Why not automate this too: it's a one-time, security-sensitive, per-host
step. Scripting it risks a broken sudoers file with no easy recovery; doing
it by hand once, with `visudo -c` validation, is safer and it's not repeated
work — it only happens again the day this moves to a new host, and it can't
be skipped since it's the moment the human decides to grant that access.

## Usage

```
terraform init
terraform apply
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes
```

## Moving to another machine

Update `target_host` (and re-run steps 1–4 above against the new host, with
the SSH bind opened beyond `127.0.0.1` if it's no longer local), then
`terraform apply` — it destroys the old install (uninstall runs via the
destroy-time provisioner) and creates the new one. No other change needed.
