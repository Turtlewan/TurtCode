---
skill: apex-k8s
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Kubernetes Docs — kubernetes.io/docs
  - Gateway API — gateway-api.sigs.k8s.io
  - Helm Docs — helm.sh/docs
  - Argo CD Docs — argo-cd.readthedocs.io
  - Karpenter — karpenter.sh
staleness_threshold: 14d
description: >
  Use when designing or reviewing Kubernetes workloads, Helm charts, cluster architecture,
  GitOps (Argo CD/Flux), networking (Gateway API, Network Policies), RBAC, or autoscaling
  (HPA/VPA/Karpenter/in-place resize). Triggers: a spec mentioning k8s, kubectl, pods,
  Deployments, StatefulSets, Helm, ArgoCD, EKS/GKE/AKS workloads, "deploy to Kubernetes".
  Not: container image build (no Dockerfile authoring), cloud infra provisioning (→ apex-iac),
  or a project that hasn't yet outgrown a managed platform (Cloud Run / App Runner /
  Container Apps) — see § When NOT to use Kubernetes.
---

# Kubernetes Specialist — Planning Mode

## When NOT to use Kubernetes (scale-gate — check first)

Kubernetes is the wrong default for most small projects. Reach for a managed container
platform (**Cloud Run, App Runner, Azure Container Apps, Fly.io, Render**) — or a single VM —
when any of these hold:
- Team < ~5 infra-capable engineers, or no one who'll own cluster upgrades.
- Fewer than ~10 services, no multi-tenant/complex-networking need.
- A single-server / local hub (e.g. an Artemis-style personal assistant) — Compose or a
  systemd unit beats a cluster.

Use Kubernetes when you genuinely need: many services with complex orchestration, bin-packing
across a fleet, mature multi-team RBAC/quota isolation, or portability across clouds. **If the
scale-gate doesn't clear, say so and stop** — don't spec a cluster the project doesn't need.

## When to activate
Any spec involving Kubernetes workload design, Helm chart creation, cluster operations,
GitOps setup (Argo CD/Flux), ingress/networking, autoscaling, RBAC, or migrating
containerised workloads to Kubernetes — **after** the scale-gate clears.

## Questions to ask before designing

- Managed K8s (EKS/GKE/AKS) or self-managed? (managed unless there's a hard reason — self-managed
  means you own cgroup/containerd/version upgrades)
- GitOps with Argo CD/Flux, or imperative kubectl? (GitOps for production)
- What are the resource requirements? (sets requests/limits, node sizing)
- Is there a service mesh requirement? (Istio/Linkerd for mTLS, traffic management — both now use
  **native sidecars**)
- North-south traffic strategy? (**Gateway API** for new clusters — see Networking)
- Stateful workloads? (StatefulSets, PVCs, storage class selection)
- GPU / accelerator workloads? (use **Dynamic Resource Allocation** — see Workload selection)

## Workload type selection

| Pattern | Resource | When |
|---------|----------|------|
| Long-running HTTP service | Deployment + HPA | Web APIs, background workers |
| Ordered, stateful service | StatefulSet | Databases, Kafka, ZooKeeper |
| One per node | DaemonSet | Log collectors, monitoring agents |
| Run-to-completion | Job / CronJob | Batch, scheduled tasks, DB migrations |
| Sidecar (log/proxy/mesh) | **init container with `restartPolicy: Always`** | Native sidecar (GA 1.33) — correct start/stop ordering |
| GPU / accelerator | Deployment + **DRA** `ResourceClaim` | AI/ML inference & training (DRA GA 1.34 replaces the device-plugin model) |

## Resource requests and limits — mandatory

Every pod must have requests AND limits. Without requests: poor scheduling. Without limits:
noisy neighbour. **Memory limit = hard ceiling (OOMKill); CPU limit = throttle (not kill).**
Set memory limit ~2× request for headroom.

```yaml
resources:
  requests: { cpu: "100m", memory: "128Mi" }   # scheduler places on requests
  limits:   { cpu: "500m", memory: "256Mi" }    # mem exceed → OOMKilled
```

Since **in-place pod resize is GA (1.35)**, CPU/memory requests can be adjusted without a pod
restart — VPA's `InPlaceOrRecreate` mode (beta) uses this.

## Autoscaling

HPA scales pod count on CPU/custom metrics (`autoscaling/v2`, `minReplicas ≥ 2` in prod). For
right-sizing requests use **VPA** (`InPlaceOrRecreate`). For nodes, **Karpenter v1** is the
default node autoscaler across **EKS / GKE / AKS / OCI** (faster + more cost-aware than Cluster
Autoscaler, which remains the fallback where Karpenter has no provider).

> HPA + PDB + VPA + in-place-resize manifests: `references/manifests.md`.

## Helm — chart structure

```
mychart/
├── Chart.yaml          # name, version, appVersion
├── values.yaml         # defaults
├── values-prod.yaml    # prod overrides
└── templates/          # deployment, service, httproute, hpa, _helpers.tpl, NOTES.txt
```

**Never hardcode image tags in templates** — pass `--set image.tag=$(git rev-parse --short HEAD)`
in CI. Install/upgrade/rollback patterns + values.yaml: `references/manifests.md`.

## GitOps with Argo CD

Code PR → merge to main → Argo CD detects diff → syncs (`automated: { prune, selfHeal }`,
`CreateNamespace=true`). No manual `kubectl apply` in production. Application manifest:
`references/manifests.md`.

## Networking

**Services:** `ClusterIP` (internal, default) · `NodePort` (dev only) · `LoadBalancer` (cloud LB).

**North-south traffic — Gateway API (new clusters).** Use the Gateway API (`GatewayClass` +
`Gateway` + `HTTPRoute`), not Ingress, for new work. **`ingress-nginx` is retired (read-only
since Mar 2026, no security patches)** — do not spec it for new clusters. Default implementation:
**Envoy Gateway** (or Cilium Gateway if the CNI is Cilium, or Istio Gateway if a mesh is present).
Ingress as an API is feature-frozen, not deprecated — existing clusters can stay, but migrate via
`ingress2gateway`.

> Gateway API `HTTPRoute` example + the Ingress→Gateway migration note: `references/gateway-api.md`.

**Network Policies:** default-deny-all + explicit allow. Required for any production cluster
handling sensitive data. Triplet (deny-all / allow-ingress / allow-DNS): `references/manifests.md`.

## RBAC — least privilege

Dedicated `ServiceAccount` per workload (never `default`); `Role` with the minimum verbs;
`RoleBinding` to the SA. **Never `cluster-admin` for application service accounts.** Manifest:
`references/manifests.md`.

## Secrets management

Do NOT commit plain Kubernetes Secrets (base64 ≠ encrypted). Use the **External Secrets Operator**
(API `external-secrets.io/v1` — `v1beta1` is removed in ESO ≥ 0.17) to sync from AWS Secrets
Manager / Vault / GCP Secret Manager. `ClusterSecretStore` + `ExternalSecret`: `references/manifests.md`.

## Health checks — mandatory for every deployment

`livenessProbe` + `readinessProbe` on every container; `startupProbe` for slow starters. Full
probe block is in the deployment template (`references/manifests.md`).

## Review checklist

- [ ] Scale-gate cleared — Kubernetes is actually warranted (not a managed platform's job)
- [ ] All pods have resource requests AND limits defined
- [ ] HPA configured for production Deployments (min ≥ 2 replicas)
- [ ] Health probes: liveness + readiness on every container
- [ ] Dedicated ServiceAccount per workload — not default SA
- [ ] Secrets from External Secrets Operator (`v1` API), not plain K8s Secrets in git
- [ ] Network Policies: default-deny with explicit ingress/egress rules
- [ ] North-south via **Gateway API** (Envoy/Cilium/Istio) — not new `ingress-nginx`
- [ ] Sidecars use the **native sidecar** pattern (init container + `restartPolicy: Always`)
- [ ] GitOps: manifests in git, Argo CD/Flux deploying — no manual kubectl apply in prod
- [ ] Non-root container user (`securityContext.runAsNonRoot: true`)
- [ ] PodDisruptionBudget for production Deployments (`minAvailable: 1`)
- [ ] Self-managed nodes only: on **cgroup v2** (cgroup v1 refused by kubelet in 1.35) and
      **not IPVS kube-proxy** (deprecated 1.35, removed 1.36)

## Standards

- Kubernetes Docs — `kubernetes.io/docs` (API reference, concepts)
- Gateway API — `gateway-api.sigs.k8s.io` (new north-south standard; `ingress2gateway` migration)
- Helm chart best practices — `helm.sh/docs/chart_best_practices`
- Argo CD — `argo-cd.readthedocs.io` (GitOps)
- Karpenter — `karpenter.sh` (node autoscaling, EKS/GKE/AKS/OCI)
