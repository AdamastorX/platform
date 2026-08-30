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

## Multi-node: adding agent hosts (backlog #48/#153, ADR 0045)

Real, physically-separate agent hosts, not VMs on the same box as the
server. `target_host` stays the one real k3s **server**; each entry in
`var.agent_hosts` joins as a real k3s **agent**.

### One-time host prep, per agent host (same shape as the server's own steps 1–4 above)

1. `openssh-server` installed and running, Terraform's SSH key in
   `~/.ssh/authorized_keys`.
2. Create `~/.adamastorx/` on the agent host, and place
   `k3s-agent-install.sh` there (path matches
   `var.remote_agent_install_script_path`):
   ```sh
   #!/bin/sh
   set -e
   . /home/<user>/.adamastorx/agent-env
   curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
     INSTALL_K3S_EXEC="agent" sh -
   ```
   `agent-env` itself is **not** placed by hand — Terraform's own
   `null_resource.k3s_agent` `scp`s it into place on every apply, sourced
   with the real, current server URL/token, before the install script runs.
3. A sudoers drop-in, same narrow-NOPASSWD shape as the server's own
   `/etc/sudoers.d/adamastorx-k3s`, extended with the agent script's path:
   ```
   # /etc/sudoers.d/adamastorx-k3s
   <user> ALL=(root) NOPASSWD: /home/<user>/.adamastorx/k3s-install.sh, /usr/local/bin/k3s-uninstall.sh, /home/<user>/.adamastorx/k3s-agent-install.sh, /usr/local/bin/k3s-agent-uninstall.sh
   ```
   `visudo -c -f <file>` before installing, `visudo -c` after — same rule
   as the server.

### Usage

```
terraform apply -var 'agent_hosts=["<agent-ip>"]'
kubectl get nodes -o wide   # confirm every node Ready, and that a real
                             # workload pod actually schedules onto an agent
                             # -- k3s puts ordinary pods on the control-plane
                             # node by default, so "Ready" alone proves nothing
```

Real values (`target_host`, `agent_hosts`, any non-default SSH
user/key) belong in a local `terraform.tfvars` (gitignored) or `-var`
flags at apply time — never committed, same reason `target_host`'s own
default stays `127.0.0.1` rather than a real host in this file.

### Removing an agent

Drop its entry from `agent_hosts`, `terraform apply` — only that one
`null_resource.k3s_agent` instance is destroyed (`for_each`, not
`count`), the server and every other agent are untouched.

**Not yet rehearsed against real hardware** — written and reviewed
before the first real `terraform apply` against any agent host, per the
same discipline `flannel-restore.md`/`hardware-migration-drill.md`
already established for this project's other risky infra changes. The
first real run is where this gets proven or a gap gets found.
