# Provisions k3s on target_host via SSH. Changing target_host replaces this
# resource: Terraform uninstalls k3s on the old host (destroy-time
# provisioner, using the connection details captured at create time), then
# installs fresh on the new one. That's the whole migration path — no other
# change needed when this moves off this machine (see platform/README.md).

resource "null_resource" "k3s" {
  # Destroy-time provisioners/connections may only reference the resource's
  # own attributes (`self`), not variables directly — route everything the
  # connection block needs through triggers so create and destroy share one
  # connection definition.
  triggers = {
    target_host          = var.target_host
    target_user          = var.target_user
    ssh_private_key_path = var.ssh_private_key_path
  }

  connection {
    type        = "ssh"
    host        = self.triggers.target_host
    user        = self.triggers.target_user
    private_key = file(self.triggers.ssh_private_key_path)
  }

  # backlog #49's own AC: "the kernel version the eBPF dataplane requires is
  # recorded as a real Terraform-level constraint", found undone during
  # #49's own real rebuild review (2026-08-10) -- Cilium's eBPF dataplane
  # (kubeProxyReplacement especially, argocd/apps/cilium.yaml) needs a
  # modern kernel; Cilium's own docs put the real floor at 5.4 for basic
  # eBPF service handling. A real, enforced precondition here, not just a
  # comment: `terraform apply` fails loudly on too-old a kernel rather
  # than succeeding and leaving Cilium to fail mysteriously afterward.
  # Confirmed live on this real host: 6.17.0-41-generic, comfortably over
  # the floor.
  provisioner "remote-exec" {
    inline = [
      "KVER=$(uname -r | cut -d. -f1,2); KMAJ=$(echo $KVER | cut -d. -f1); KMIN=$(echo $KVER | cut -d. -f2); if [ \"$KMAJ\" -lt 5 ] || { [ \"$KMAJ\" -eq 5 ] && [ \"$KMIN\" -lt 4 ]; }; then echo \"kernel $(uname -r) is below Cilium's real eBPF floor (5.4) -- see backlog #49\" >&2; exit 1; fi; echo \"kernel $(uname -r) OK for Cilium eBPF (>= 5.4)\"",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo ${var.remote_install_script_path}",
      "systemctl is-active k3s",
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      scp -i ${var.ssh_private_key_path} -o StrictHostKeyChecking=accept-new \
        ${var.target_user}@${var.target_host}:/etc/rancher/k3s/k3s.yaml \
        ${path.module}/kubeconfig
      sed -i 's/127.0.0.1/${var.target_host}/' ${path.module}/kubeconfig
      chmod 600 ${path.module}/kubeconfig
    EOT
  }

  # backlog #48's own AC: the join token is needed to create the cluster,
  # over SSH, before kubectl is meaningfully usable on any agent -- Terraform/
  # SSH domain, not Kubernetes-API domain, so it can't go through
  # bootstrap/create-stateful-secrets.sh's existing kubectl-based pattern.
  # Same local-artifact shape as kubeconfig above: fetched off the server,
  # chmod 600, gitignored, never committed, never round-tripped through a
  # kubectl Secret. SOPS+age (ADR 0034) deliberately not extended to this
  # value -- #48's own AC has the full reasoning (losing this laptop takes
  # the token's server, its own agents, and its own consumer down together,
  # so a recovery copy would protect nothing that isn't already gone).
  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.ssh_private_key_path} -o StrictHostKeyChecking=accept-new \
        ${var.target_user}@${var.target_host} \
        "sudo cat /var/lib/rancher/k3s/server/node-token" > ${path.module}/node-token
      chmod 600 ${path.module}/node-token
    EOT
  }

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "sudo /usr/local/bin/k3s-uninstall.sh",
    ]
  }
}

# backlog #48's own AC, applied to real agent hosts instead of the VM agents
# that AC was originally scoped for (that item closed Won't do/superseded --
# a second *VM* on the *same, already-saturated laptop* couldn't fit; the
# Terraform mechanism it designed was never the problem). for_each over a
# set, not count -- adding/removing one host from agent_hosts must not
# reindex and touch every other agent, only the one that actually changed.
#
# Deviates from #48's literal remote-exec-with-its-own-connection-block
# shape for one concrete reason: passing K3S_URL/K3S_TOKEN to a sudo'd
# install script over a plain remote-exec connection needs either dynamic
# sudo env-passthrough (a SETENV sudoers tag, easy to get subtly wrong) or
# the values landing in a file first. This uses local-exec end to end: scp
# a small, narrowly-permissioned env file to the agent, then ssh in to run
# the (still sudoers-whitelisted, still narrowly-scoped) install script,
# which sources that file itself -- no sudoers change beyond adding the one
# new script path, same shape the existing k3s-install.sh entry already has.
resource "null_resource" "k3s_agent" {
  for_each = toset(var.agent_hosts)

  triggers = {
    agent_host           = each.value
    agent_target_user    = var.agent_target_user
    ssh_private_key_path = var.ssh_private_key_path
    server_host          = var.target_host
  }

  depends_on = [null_resource.k3s]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      ENV_FILE=$(mktemp)
      printf 'K3S_URL=https://%s:6443\nK3S_TOKEN=%s\n' \
        "${var.target_host}" "$(cat ${path.module}/node-token)" > "$ENV_FILE"
      scp -i "${var.ssh_private_key_path}" -o StrictHostKeyChecking=accept-new \
        "$ENV_FILE" "${var.agent_target_user}@${each.value}:/home/${var.agent_target_user}/.adamastorx/agent-env"
      rm -f "$ENV_FILE"
      ssh -i "${var.ssh_private_key_path}" -o StrictHostKeyChecking=accept-new \
        "${var.agent_target_user}@${each.value}" \
        "chmod 600 /home/${var.agent_target_user}/.adamastorx/agent-env && \
         sudo ${var.remote_agent_install_script_path} && \
         systemctl is-active k3s-agent"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      ssh -i "${self.triggers.ssh_private_key_path}" -o StrictHostKeyChecking=accept-new \
        "${self.triggers.agent_target_user}@${self.triggers.agent_host}" \
        "sudo /usr/local/bin/k3s-agent-uninstall.sh"
    EOT
  }
}
