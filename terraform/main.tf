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

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "sudo /usr/local/bin/k3s-uninstall.sh",
    ]
  }
}
