# Terraform
> An infrastructure-as-code tool that builds the entire "bare metal → running cluster" path from committed text in one `apply`.

**What it is.** Terraform is the most common infrastructure-as-code (IaC) tool: your VMs, networks, and config live in version-controlled `.tf` files instead of being clicked into existence. Mental model: a general contractor with a blueprint (your files) and a ledger of what it has already built (the *state file*). You say "make reality match the blueprint"; it computes the minimum set of changes and runs them. Re-running when nothing changed does nothing — that property is *idempotence*.

**How it works.** *Providers* are plugins teaching Terraform to talk to a system (here `bpg/proxmox` makes VMs, `siderolabs/talos` generates+applies machine config and bootstraps etcd). *Resources* are things to create; *data sources* read without creating. `terraform plan` shows a dry-run diff before any change — the safety feature that makes IaC reviewable; `apply` executes it; `destroy` tears it down. *State* (`terraform.tfstate`) maps config to real object IDs and can hold secrets (the Talos PKI, kubeconfig), so it's gitignored.

**In this cluster.**
- `terraform/vms.tf` (6 VMs from one `for_each`), `terraform/talos.tf` (`talos_machine_secrets` → `..._configuration_apply` → `..._bootstrap` → `..._kubeconfig`), `terraform/locals.tf` (node inventory). `talos.tf` reads the *same* hand-written `talos/patches/*` files so manual and TF paths can't drift.
- See it live: `cd terraform && terraform plan` — read-only diff against the live cluster's adopted state.

**See also:** [[proxmox]] · [[talos-linux]] · [[gitops]] · [[sops]] · [[argo-cd]] &nbsp; **Deep dive:** [[01-foundations]]
