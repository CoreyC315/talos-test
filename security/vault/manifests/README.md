# Vault — manual bootstrap

Vault ships sealed and uninitialized. These steps are intentionally manual
(one-time, secrets never touch git). Run them after the `vault` Application is
healthy enough that the `vault-0` pod is Running (it will report 0/1 Ready
until unsealed — that is expected).

## 1. Initialize (single key share — homelab tradeoff)

```sh
kubectl -n vault exec -it vault-0 -- \
  vault operator init -key-shares=1 -key-threshold=1
```

Save the **Unseal Key** and **Initial Root Token** somewhere safe
(password manager). They are shown exactly once.

## 2. Unseal

```sh
kubectl -n vault exec -it vault-0 -- \
  vault operator unseal <UNSEAL_KEY>
```

Repeat after every pod restart (standalone file storage, no auto-unseal).

## 3. Login and enable the kv-v2 engine at `kubeshowcase`

```sh
kubectl -n vault exec -it vault-0 -- vault login <ROOT_TOKEN>
kubectl -n vault exec -it vault-0 -- \
  vault secrets enable -path=kubeshowcase kv-v2
```

## 4. Enable Kubernetes auth (used by External Secrets Operator)

```sh
kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes

kubectl -n vault exec -it vault-0 -- sh -c '
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
```

Create a read-only policy and the `eso-reader` role bound to the
`external-secrets` ServiceAccount (matches the `vault-kv` ClusterSecretStore
in `security/eso/vault-store.yaml`):

```sh
kubectl -n vault exec -it vault-0 -- sh -c '
  vault policy write eso-reader - <<EOF
path "kubeshowcase/data/*" {
  capabilities = ["read"]
}
path "kubeshowcase/metadata/*" {
  capabilities = ["read", "list"]
}
EOF'

kubectl -n vault exec -it vault-0 -- \
  vault write auth/kubernetes/role/eso-reader \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=eso-reader \
    ttl=1h
```

## 5. Smoke test

```sh
kubectl -n vault exec -it vault-0 -- \
  vault kv put kubeshowcase/hello foo=bar
```

UI: http://vault.192.168.1.27.nip.io (login with the root token).
