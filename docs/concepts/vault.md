# HashiCorp Vault
> A dedicated secrets manager that stores credentials, controls who can read them, and can mint short-lived secrets on demand.

**What it is.** Vault is a hardened vault (literally) that stores secrets, controls access, and can *generate short-lived* credentials. Mental model: a bank vault with a teller. Secrets go in the safe; nobody reads them directly — they present **identity** to the teller (an auth method), the teller checks their **policy**, and hands back only the specific secret for a limited time. The point: secrets live in one audited, access-controlled place, never scattered across YAML or Git (contrast [[sops]], which encrypts secrets *in* Git).

**How it works.** Four concepts: (1) **seal/unseal** — Vault starts sealed/encrypted and is unsealed with key shares (Shamir's Secret Sharing); (2) **secrets engines** mounted at a path, the simplest being **KV** (others mint DB creds, PKI certs, cloud tokens dynamically); (3) **auth methods** — how a client proves identity (token, AppRole, and crucially **Kubernetes auth**: a pod presents its ServiceAccount JWT, Vault verifies it with the API server); (4) **policies** — HCL granting read/list on specific paths. Identity + policy = least-privilege access.

**In this cluster.**
- `apps/security/vault.yaml` (chart 0.33.0, wave 5) runs Vault **standalone** on a 2Gi [[longhorn]] volume, UI on, agent injector off (ESO pulls instead). It ships sealed/uninitialized on purpose; `security/vault/seed-vault.sh` does the one-time bootstrap (kv-v2 at `kubeshowcase`, kubernetes auth, `eso-reader` policy/role) so the root token never touches Git.
- Read-only check: `kubectl -n vault exec vault-0 -- vault status` (Sealed: false, Initialized: true).

**See also:** [[external-secrets]] · [[sops]] · [[rbac]] · [[longhorn]] · [[cert-manager]] &nbsp; **Deep dive:** [[07-security-governance]]
