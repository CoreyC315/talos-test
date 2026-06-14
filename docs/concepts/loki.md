# Loki
> A log database that indexes only labels (not log text) and stores raw lines cheaply in object storage — "Prometheus, but for logs."

**What it is.** Loki is a log aggregation database from Grafana Labs. Its key idea: **don't index the log text, only index a few labels** (namespace, pod, container), store the raw log lines compressed in cheap object storage, and brute-force-scan them at query time. Analogy: instead of building a giant searchable index of every word in every book (expensive, like Elasticsearch), Loki labels each *shelf* (pod) and reads the books on the relevant shelf when you ask — much cheaper, slightly slower for needle-in-haystack full-text search.

**How it works.** A *stream* is a unique label set (e.g. `{namespace="kubeshowcase", pod="ks-api-xyz", container="api"}`); each stream is an append-only log of lines. You query with **LogQL**, which deliberately mirrors PromQL: `{namespace="kubeshowcase"} |= "error"` filters lines, and you can even turn logs into metrics with `rate({namespace="kubeshowcase"} |= "error" [5m])`. The index plus compressed log chunks go to object storage. Loki can run as a single binary, "simple scalable," or full microservices; this cluster runs **SingleBinary** with caches off because the nodes are RAM-constrained.

**In this cluster.**
- `apps/observability/loki.yaml` (chart `7.0.0`, `deploymentMode: SingleBinary`): storage is **MinIO** (buckets `loki-chunks`/`loki-ruler`, endpoint `minio.minio.svc.cluster.local:9000`), 72h retention. Alloy pushes logs to the `loki-gateway` Service.
- `export KUBECONFIG=$PWD/terraform/.kubeconfig && kubectl port-forward -n monitoring svc/loki-gateway 8080:80 &` then `curl -s -G 'http://localhost:8080/loki/api/v1/labels' | jq .` — returns `namespace`, `pod`, `container`.

**See also:** [[promql]] · [[grafana]] · [[alloy]] · [[tempo]] · [[minio]] · [[observability-pillars]] &nbsp; **Deep dive:** [[06-observability]]
