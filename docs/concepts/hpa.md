# Horizontal Pod Autoscaler
> A controller that adds/removes pod replicas to keep a chosen metric near its target.

**What it is.** A thermostat for pods: set "keep CPU at 60%," and it adds replicas when you're hot, removes them when you're cool, between a `min` and `max`. It's the hub of the autoscaling story — [[vpa-goldilocks|VPA]] resizes pods instead, and [[keda]] doesn't replace the HPA, it *generates* one.

**How it works.** Every ~15s it computes `desiredReplicas = ceil(currentReplicas × currentMetric / targetMetric)`, clamps to `[min,max]`, and patches the target's replica count. `autoscaling/v2` supports multiple metrics at once (takes the **max** desired count, so the busiest signal wins) and several types: `Resource` (CPU/mem from [[metrics-server]]), `Pods`/`Object` (custom metrics via [[prometheus-adapter]]), `External` ([[keda|KEDA]]'s lane). A `behavior` block adds stabilization windows (scale up fast, down slow). It targets anything with a `/scale` subresource — including an [[argo-rollouts|Argo Rollout]].

**In this cluster.**
- `workloads/kubeshowcase/autoscaling.yaml` defines the `ks-api` HPA: `minReplicas: 2`, `maxReplicas: 6`, **two** metrics — `Resource` CPU at `60%` *and* `Pods` `http_requests_per_second` at avg `20`. `scaleTargetRef` is `kind: Rollout` (not a Deployment). `behavior`: scale up after 30s, down after 120s.
- Live: `kubectl get hpa ks-api -n kubeshowcase` — `TARGETS` shows both signals, e.g. `cpu: 1%/60%, 366m/20`.

**See also:** [[metrics-server]] · [[prometheus-adapter]] · [[keda]] · [[vpa-goldilocks]] · [[argo-rollouts]] · [[requests-and-limits]] &nbsp; **Deep dive:** [[05-scaling-scheduling]]
