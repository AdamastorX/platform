variable "target_host" {
  description = "Host to install k3s on. Defaults to this machine (M1 runs locally); swap to a real IP when moving to dedicated hardware — nothing else in this module changes."
  type        = string
  default     = "127.0.0.1"
}

variable "target_user" {
  description = "SSH user on the target host. Must have the scoped sudoers NOPASSWD entry for the k3s install/uninstall scripts (see platform/README.md)."
  type        = string
  default     = "lmpeixoto"
}

variable "ssh_private_key_path" {
  description = "Private key used to SSH into target_host."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "remote_install_script_path" {
  description = "Path on target_host where the k3s install script must already exist (see platform/README.md for setup)."
  type        = string
  default     = "/home/lmpeixoto/.adamastorx/k3s-install.sh"
}
