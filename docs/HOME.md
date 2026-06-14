# 🧭 KubeShowcase Knowledge Vault — Start Here

**If you are an AI agent or a new engineer: read this note, then follow the `[[links]]`.** This is
an Obsidian vault (plain Markdown + wikilinks — open the `docs/` folder as a vault, or just read the
files). Everything you need to understand, operate, or extend this cluster is reachable from here.

> **What this cluster is, in one line:** a 6-node Talos Linux + Kubernetes platform on 3 Proxmox
> hosts (one control plane + one worker each), reconciled by [[argo-cd|Argo CD]] from this Git repo,
> running full observability, security/governance, distributed storage, and a demo app — all
> rebuildable with `terraform apply`.

## The three layers (pick by what you need *right now*)

| You want to… | Go to | What it is |
|---|---|---|
| **Fix something that's broken** | [[OPERATIONS]] | Dense triage: symptom → cause → fix, where every key/config lives, what's normal vs broken |
| **Know what a tool *is*** (fast) | [[concepts/index\|🗂 Concept Index]] | ~60 atomic cards: each tool in a paragraph + how it works + where it's used here + links |
| **Actually *learn* the stack** (deep) | [[learn/README\|📚 Curriculum]] | 8 weekend modules with hands-on labs on the live cluster + interview/cert prep |
| **Rebuild or restore it** | [[REBUILD]] | Fresh build, adopt-existing, and data-restore runbook |
| **See past failures + fixes** | [[talos-gotchas]] · [[resilience-report]] | 14 real failure→fix writeups; 5 incidents + the clean-room rebuild |
| **See every feature + how to observe it** | [[feature-matrix]] | One row per demonstrated capability |

## How to navigate this vault
- **Concept cards** ([[concepts/index]]) are the heart of the graph — short, single-topic, heavily
  cross-linked. Start at any tool you don't recognize and let the `See also` links pull you around.
- Each card ends with a **Deep dive** link to its full curriculum module, and a [[OPERATIONS]] link
  if it has a known operational gotcha.
- In Obsidian, open **Graph view** to see the whole system as a map; use **Backlinks** on any note
  to see what depends on it.

## The 60-second mental model
```
  Proxmox (hosts)
    └─ Talos Linux VMs ──> Kubernetes (etcd/apiserver/kubelet)
         ├─ Cilium ........ networking (pods talk; Gateway lets the world in)
         ├─ Argo CD ....... GitOps — makes the cluster match THIS repo
         ├─ Longhorn ...... storage; CloudNativePG ... HA Postgres
         ├─ LGTM .......... observability (Prometheus/Loki/Tempo/Grafana)
         ├─ Kyverno/Falco/Trivy/Vault ... security & secrets
         └─ KEDA/HPA + Argo Rollouts .... scaling & safe releases
```
New to all of it? Read [[learn/README#the-decoder-ring--what-even-is-that-in-one-line-each|the decoder ring]]
(one line per tool), then come back and browse the concept cards.

## Vault map
- `docs/HOME.md` — **you are here** (the entry note)
- `docs/concepts/` — atomic concept cards + [[concepts/index|the index]]
- `docs/learn/` — the deep curriculum (8 modules + master README)
- `docs/OPERATIONS.md`, `REBUILD.md`, `talos-gotchas.md`, `resilience-report.md`, `feature-matrix.md`
- The live cluster + the manifests in this repo are always the ultimate source of truth.
