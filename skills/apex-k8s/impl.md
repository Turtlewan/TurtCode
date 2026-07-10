---
skill: apex-k8s
backend: coding
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Kubernetes Docs — kubernetes.io/docs
  - Gateway API — gateway-api.sigs.k8s.io
  - External Secrets Operator — external-secrets.io
staleness_threshold: 14d
description: >
  Use when implementing Kubernetes manifests, Helm charts, or GitOps config in coding mode.
  Triggers: writing Deployments/Services/HPA/NetworkPolicy/HTTPRoute YAML, ESO secret stores,
  Argo CD Applications, kubectl operations. Not: cluster architecture decisions (SKILL.md).
---

# Kubernetes — Coding Patterns

## Stack assumptions

Kubernetes manifests are cloud-agnostic — these patterns hold on EKS/GKE/AKS and self-managed.
Cloud-specific bits are isolated: **ESO provider** (AWS Secrets Manager / Vault / GCP),
**LoadBalancer annotations**, and the **node autoscaler** (Karpenter v1 on EKS/GKE/AKS/OCI; else
Cluster Autoscaler). Assume **managed K8s** unless the spec says self-managed (then also confirm
cgroup v2 nodes and a non-IPVS kube-proxy — see NEVER).

## NEVER / ALWAYS

NEVER:
- Use `latest` image tag in production — pin to a digest or semver tag
- Run containers as root — set `runAsNonRoot: true` and `runAsUser: 1000`
- Use the `default` ServiceAccount for application workloads
- Store secrets in plain Kubernetes Secrets committed to git (base64 ≠ encrypted)
- Skip resource requests/limits — scheduling and stability depend on them
- Use `kubectl apply -f` directly in production — use GitOps (Argo CD/Flux)
- Spec **`ingress-nginx`** for a new cluster — it is retired (no security patches); use Gateway API
- Use `external-secrets.io/v1beta1` — it's removed in ESO ≥ 0.17; use `external-secrets.io/v1`
- Configure IPVS kube-proxy on self-managed clusters (deprecated 1.35, removed 1.36)

ALWAYS:
- Set `requests` AND `limits` on every container
- Add `readinessProbe` and `livenessProbe` to every container
- Use `PodDisruptionBudget` for production Deployments
- Set `minReplicas: 2` (or more) in HPA for production
- Implement sidecars as **native sidecars** (init container + `restartPolicy: Always`)
- Apply with `--server-side` (server-side apply handles last-applied state)

## Manifests (templates)

> Full production templates — Deployment (+ native sidecar), HPA + PDB, ESO `v1`, RBAC,
> Argo CD Application, Helm values.yaml, Network Policy triplet: read `references/manifests.md`.
> Gateway API (`GatewayClass`/`Gateway`/`HTTPRoute`) + Ingress→Gateway migration:
> read `references/gateway-api.md`.

## kubectl — daily commands

```bash
# Context
kubectl config get-contexts && kubectl config use-context prod-cluster

# Apply (server-side) + rollout
kubectl apply -f k8s/ --server-side
kubectl rollout restart deployment/my-app -n my-app      # picks up new secret values
kubectl rollout status  deployment/my-app -n my-app

# Debug a crashing pod
kubectl describe pod -l app=my-app -n my-app
kubectl logs -l app=my-app -n my-app --previous          # logs from crashed container
kubectl exec -it deployment/my-app -n my-app -- /bin/sh
kubectl port-forward service/my-app 3000:3000 -n my-app
kubectl top pods -n my-app && kubectl top nodes

# Helm install / upgrade
helm upgrade --install my-app ./charts/my-app -f values-prod.yaml \
  --set image.tag=$(git rev-parse --short HEAD) -n my-app --create-namespace

# Argo CD sync
argocd app sync my-app && argocd app wait my-app --health
```

## Common errors → fix

| Symptom | Fix |
|---------|-----|
| Pod `CrashLoopBackOff` | `kubectl logs --previous`; check liveness probe path/port + start time vs `initialDelaySeconds` |
| Pod `OOMKilled` | memory *limit* too low — raise it (or in-place resize); limit is the hard ceiling |
| `Pending` pod, no node | requests too high / no capacity — check Karpenter/CA + `kubectl describe pod` events |
| `ImagePullBackOff` | tag/digest wrong or registry auth — verify image ref + imagePullSecrets |
| ESO secret not syncing | wrong API version (`v1` not `v1beta1`), or SecretStore auth/IRSA misconfigured |
| 404 / no route to service | Gateway `HTTPRoute` `backendRefs` name/port mismatch, or listener hostname mismatch |
| NetworkPolicy blocks traffic | default-deny in place but no `allow-dns` / `allow-from-gateway` rule |

## Verification checklist

- [ ] All containers have `requests` and `limits` defined
- [ ] `readinessProbe` and `livenessProbe` on every container
- [ ] Containers run as non-root (`runAsNonRoot: true`, `runAsUser: 1000`)
- [ ] `readOnlyRootFilesystem: true` with `emptyDir` for `/tmp`
- [ ] `allowPrivilegeEscalation: false`, all capabilities dropped
- [ ] Dedicated ServiceAccount per workload (not `default`)
- [ ] Secrets via External Secrets Operator (`v1` API) — not plain K8s Secrets in git
- [ ] HPA with `minReplicas ≥ 2` in production; PodDisruptionBudget `minAvailable: 1`
- [ ] Network Policies: default-deny with explicit allow rules
- [ ] North-south via Gateway API (`HTTPRoute`) — not new `ingress-nginx`
- [ ] Sidecars use native-sidecar pattern (init container + `restartPolicy: Always`)
- [ ] Image tag pinned to digest or semver (never `latest` in prod)
- [ ] Deployed via Argo CD/GitOps — no manual `kubectl apply` in production
