# Scheduling Constraints
> The declarative hints that steer which node each pod lands on — and protect pods during voluntary disruptions.

**What it is.** The [[kube-scheduler|scheduler]] is a matchmaker: for every pod it **filters** (which nodes *could* host it?) then **scores** (which is *best*?). You influence it with hints on the pod. Analogy: a seating host who first crosses off tables that are too small or reserved, then picks the nicest one left by your preferences.

**How it works.** The levers: **nodeSelector / nodeAffinity** ("only on nodes with label X"; affinity adds hard `required` vs soft `preferred`). **podAffinity / podAntiAffinity** (schedule near/away from matching pods — e.g. keep replicas off one host). **Taints & tolerations** — a taint on a *node* repels pods (`NoSchedule`); a toleration on a *pod* is the permission slip to land anyway (this keeps workloads off control-plane nodes). **topologySpreadConstraints** spread replicas across a domain (hostname, zone) with `maxSkew` and `DoNotSchedule` (hard) or `ScheduleAnyway` (soft). A **PodDisruptionBudget (PDB)** is a *disruption* rule, not placement — it tells `kubectl drain`/eviction "never take me below `minAvailable`."

**In this cluster.**
- Control-plane nodes carry `node-role.kubernetes.io/control-plane:NoSchedule`, so app pods only run on workers.
- `workloads/kubeshowcase/api.yaml` spreads `ks-api` across `hostname` *and* `zone` (`maxSkew: 1`, `ScheduleAnyway`); `frontend.yaml` spreads across hostname only. PDBs in `pdb.yaml` — `ks-api`/`ks-frontend` use `minAvailable: 1`; `redis` uses `maxUnavailable: 1` on purpose (a single-replica `minAvailable: 1` would deadlock a drain). See [[OPERATIONS]].
- Live: `kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'`

**See also:** [[requests-and-limits]] · [[kube-scheduler]] · [[kubelet]] · [[statefulset]] · [[longhorn]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
