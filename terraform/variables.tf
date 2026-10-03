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
  # Real incident, 2026-08-10: Terraform's file() function does not do
  # shell-style ~ expansion (Go's file-open just takes it literally), so
  # the old "~/.ssh/id_ed25519" default failed both the original apply's
  # destroy-time provisioner (triggers.ssh_private_key_path is captured
  # into state at create time, so a later -var override on destroy
  # doesn't help either -- the state itself needed a manual fix) and
  # would fail identically on every future rebuild. Absolute path,
  # matching remote_install_script_path's own already-absolute default
  # below, rather than reintroducing the same footgun.
  description = "Private key used to SSH into target_host."
  type        = string
  default     = "/home/lmpeixoto/.ssh/id_ed25519"
}

variable "remote_install_script_path" {
  description = "Path on target_host where the k3s install script must already exist (see platform/README.md for setup)."
  type        = string
  default     = "/home/lmpeixoto/.adamastorx/k3s-install.sh"
}

variable "agent_hosts" {
  # backlog #48's own AC named both agent_count and agent_hosts; this
  # module intentionally only has the latter (count = length(var.agent_hosts))
  # so the two can never drift out of sync with each other -- the risk a
  # separate agent_count variable would add for no real benefit.
  description = "SSH-reachable hosts to join as k3s agents (real physical/VM hosts, provisioned by hand in the same one-time host-prep step target_host already documents -- Terraform installs k3s onto hosts that already exist, per ADR 0002, it doesn't provision the compute itself). Empty by default: the single-node path stays supported as a variable, not a fork (ADR 0035/0040 precedent)."
  type        = list(string)
  default     = []
}

variable "agent_target_user" {
  description = "SSH user on each agent host. Same default as target_user -- override if an agent host uses a different account."
  type        = string
  default     = "lmpeixoto"
}

variable "remote_agent_install_script_path" {
  description = "Path on each agent host where the k3s agent install script must already exist (sibling to remote_install_script_path -- see platform/README.md for setup)."
  type        = string
  default     = "/home/lmpeixoto/.adamastorx/k3s-agent-install.sh"
}
