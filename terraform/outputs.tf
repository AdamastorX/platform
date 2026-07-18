output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig. Use: export KUBECONFIG=$(terraform output -raw kubeconfig_path)"
  value       = "${path.module}/kubeconfig"
}

output "target_host" {
  value = var.target_host
}
