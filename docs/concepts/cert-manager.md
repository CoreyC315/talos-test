# cert-manager
> A controller that treats a TLS certificate as a Kubernetes resource you declare, then issues, stores, and auto-renews it before it expires — so nobody touches certs by hand.

**What it is.** Before cert-manager, "the cert expired at 2am and the site went down" was a classic outage. Now you write a `Certificate` and forget it: cert-manager issues it, stores it in a [[service|Secret]], and renews it ahead of expiry, automatically. Analogy: a subscription that mails you a fresh passport before the old one expires, so you never get stuck at the border.

**How it works.** You define an **Issuer**/`ClusterIssuer` (where certs come from — Let's Encrypt via ACME, or a private CA) and a **`Certificate`** (DNS names, duration, `renewBefore`). cert-manager generates a key + CSR, gets it signed by the issuer, and writes the result into a Secret. This repo builds a realistic **PKI chain**: a self-signed bootstrap issuer → a 10-year root CA → a 5-year intermediate CA → the `homelab-ca` `ClusterIssuer` that signs all leaf certs. You trust the *root* once on your workstation, and leaves rotate freely underneath it — exactly how corporate CAs work. Pair it with [[reloader|Reloader]] so workloads pick up rotated cert Secrets.

**In this cluster.**
- Controller (Helm `cert-manager` v1.20.2, CRDs enabled) + a config App: `apps/platform/cert-manager.yaml`; the CA chain: `platform/cert-manager/ca-chain.yaml`.
- The `wildcard-tls` `Certificate` for `*.192.168.1.27.nip.io` (90d duration, renew 15d early), consumed by the [[gateway-api|Gateway]] HTTPS listener: `platform/gateway/gateway.yaml`.
- Live: `kubectl get clusterissuer` (all `READY=True`)

**See also:** [[gateway-api]] · [[reloader]] · [[vault]] · [[external-secrets]] · [[gitops]] &nbsp; **Deep dive:** [[08-release-ops]]
