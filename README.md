# platform

Infrastructure for AdamastorX: Terraform, Helm, ArgoCD, Kubernetes manifests,
cluster bootstrap. No application code here — see
[services](https://github.com/AdamastorX/services).

Empty scaffold as of M0. First real content lands with milestone **M1
Platform Bootstrap** — see backlog issues #5–#10 in the
[adamastorx](https://github.com/AdamastorX/adamastorx) repo's
`docs/roadmap/backlog.md`.

## Layout

| Dir | Contents |
|---|---|
| `terraform/` | Cluster provisioning (k3s) |
| `helm/` | Charts for anything not better served by ArgoCD app manifests directly |
| `argocd/` | Application/app-of-apps definitions — the GitOps entrypoint |
| `kubernetes/` | Raw manifests that don't warrant a Helm chart |
| `bootstrap/` | One-time cluster bootstrap steps (installing ArgoCD itself, etc.) |

## Engineering context

Full project context, workflow, and agent roles: see the `adamastorx` repo's
`.claude/PROJECT.md` and `.claude/WORKFLOW.md` — this repo's `.claude/`
just points there, on purpose, so context has one home instead of four
copies drifting apart.
