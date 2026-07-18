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
