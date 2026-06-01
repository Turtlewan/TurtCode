---
skill: apex-k8s
backend: claude
version: 1.2.0
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
  or before weighing whether a managed platform / single VM fits better (see § Orchestration
  options).
---

# Kubernetes Specialist — Planning Mode

## Orchestration options — weigh before choosing Kubernetes

Don't reach for Kubernetes by default. Present the realistic options and their trade-offs, then
let the user decide:

| Option | Good for | Trade-offs |
|--------|----------|-----------|
| Single VM + Compose / systemd | one box, a few services, a personal/local hub (e.g. Artemis) | simplest ops; no self-healing or auto-scale; manual scaling; single host is a SPOF |
| Managed container platform (Cloud Run, App Runner, Container Apps, Fly.io, Render) | small teams, bursty/stateless web services, zero cluster ops wanted | fast + cheap to run, no node management; less control over networking/scheduling; per-platform limits; possible cold starts |
| Kubernetes (managed: EKS/GKE/AKS) | many services, complex orchestration, fleet bin-packing, multi-team RBAC/quota, cloud portability | most powerful + portable; real ops burden (upgrades, networking, RBAC); overkill below ~10 services or without someone to own upgrades |

Rule of thumb: below ~10 services, or with no one to own cluster upgrades, a managed platform or a
single VM usually wins. **State the recommendation and the trade-off being accepted, then let the
user decide** — don't silently spec a cluster, but don't refuse one the user deliberately wants.

## When to activate
Any spec involving Kubernetes workload design, Helm chart creation, cluster operations,
GitOps setup (Argo CD/Flux), ingress/networking, autoscaling, RBAC, or migrating
containerised workloads to Kubernetes — once the orchestration options above have been weighed.

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
right-sizing requests use **VPA** (`InPlaceOrRecreate`). For node autoscaling, weigh the two at
decision point (no default):
- **Karpenter v1** — provisions right-sized nodes fast, better bin-packing / cost-awareness; GA
  across EKS/GKE/AKS/OCI. Trade-off: newer, provider-specific setup, another controller to run.
- **Cluster Autoscaler** — mature, ubiquitous, works wherever node groups exist. Trade-off:
  slower to react, node-group-bound (less bin-packing flexibility).

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
since Mar 2026, no security patches)** — do not spec it for new clusters. Pick the implementation
at decision point (no single default — it depends on the cluster):

| Implementation | Pros | Cons |
|----------------|------|------|
| Envoy Gateway | CNCF, standalone, widely adopted for new clusters; no mesh required | one more component to run/upgrade |
| Cilium Gateway API | reuses the CNI if already on Cilium — no extra proxy | only when Cilium is the CNI |
| Istio Gateway | natural if a service mesh is already present | heavy if you don't otherwise need a mesh |
| Cloud-native (GKE/AWS Gateway controllers) | managed, integrates with the cloud LB | cloud-specific, less portable |

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

- [ ] Orchestration options weighed — Kubernetes chosen with its trade-offs acknowledged (not by default)
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
