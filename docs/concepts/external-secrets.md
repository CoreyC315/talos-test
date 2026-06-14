# External Secrets Operator
> The bridge that logs into Vault and continuously syncs its secrets into native Kubernetes Secret objects.

**What it is.** Pods consume secrets as native Kubernetes `Secret` objects, but [[vault]] stores them elsewhere. The External Secrets Operator (ESO) is the bridge: it authenticates to Vault on the cluster's behalf, fetches the value, and continuously syncs it into a normal `Secret`. Mental model: a courier who, on a schedule, walks to the bank vault, withdraws exactly the documents you're authorized for, and drops a fresh copy in your office mailbox — so your app just reads its mailbox and never needs the vault's combination.

**How it works.** Two CRDs. A **SecretStore**/**ClusterSecretStore** describes *where* and *how* to authenticate (provider, server URL, auth role). An **ExternalSecret** describes *what* to fetch and *where to put it*: it references a store, maps remote keys to local secret keys, and ESO creates and owns the target `Secret`, refreshing on `refreshInterval`. If the value rotates in Vault, the Kubernetes Secret updates automatically — no commit, no redeploy (contrast [[sops]]: secrets encrypted in Git, rotated by PR).

**In this cluster.**
- `apps/security/external-secrets.yaml` installs the operator (wave 5); `apps/security/eso-config.yaml` deploys the store on wave 6. `security/eso/vault-store.yaml` is `ClusterSecretStore` `vault-kv` → `http://vault.vault.svc:8200`, path `kubeshowcase`, kubernetes auth role `eso-reader`. Consumer: `workloads/kubeshowcase/external-secret.yaml` pulls `kubeshowcase/api` into Secret key `VAULT_MESSAGE`, refreshed every `1m`.
- Trace the chain: `kubectl -n kubeshowcase get externalsecret` then `kubectl -n kubeshowcase get secret ks-vault-secret -o jsonpath='{.data.VAULT_MESSAGE}' | base64 -d`

**See also:** [[vault]] · [[sops]] · [[rbac]] · [[gitops]] · [[argo-cd]] &nbsp; **Deep dive:** [[07-security-governance]]
