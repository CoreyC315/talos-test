# SOPS / age / KSOPS
> Three cooperating tools that let you commit *encrypted* secrets to Git safely — the file in Git is ciphertext, and only the cluster holds the key to decrypt it at render time.

**What it is.** GitOps wants *everything* in Git, but you must never commit a plaintext password. **SOPS** (Secrets OPerationS) encrypts a YAML file's *values* while leaving keys/structure readable — a **selective redactor** that blacks out only secrets, so diffs still make sense. **age** is the modern encryption tool providing the keypair: the public key (`age1...`) lives in Git and encrypts; the private key never leaves your machine and the cluster. **KSOPS** is a [[kustomize|Kustomize]] plugin that calls SOPS to decrypt `*.sops.yaml` files at render time.

**How it works.** `.sops.yaml` holds **creation rules**: which files to encrypt, with which age recipient, and `encrypted_regex: ^(data|stringData)$` so only secret *values* are encrypted (metadata stays diffable). `sops -e` turns each value into `ENC[AES256_GCM,...]` and appends a `sops:` block with the age-encrypted data key and a MAC (tamper check). In-cluster, [[argo-cd|Argo CD]]'s repo-server mounts the age private key (`SOPS_AGE_KEY_FILE=/sops-age/keys.txt`) and runs KSOPS at sync time, so plaintext exists only in memory, never in Git.

**In this cluster.**
- Config: `.sops.yaml` (the recipient + `encrypted_regex`). An encrypted secret: `platform/longhorn/manifests/minio-credentials.sops.yaml` (keys readable, values `ENC[...]`). Generator wiring: `platform/longhorn/manifests/ksops-generator.yaml`. The age key Secret (the one thing *not* in Git) is created by `bootstrap/02-bootstrap-argocd.sh`.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl get secret minio-credentials -n longhorn-system -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d; echo` — the decrypted result KSOPS produced.

**See also:** [[kustomize]] · [[argo-cd]] · [[gitops]] · [[external-secrets]] · [[vault]] · [[longhorn]] &nbsp; **Deep dive:** [[03-gitops]]
