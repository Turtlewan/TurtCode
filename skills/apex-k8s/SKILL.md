---
skill: apex-k8s
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Kubernetes Docs — kubernetes.io/docs
  - Helm Docs — helm.sh/docs
  - ArgoCD Docs — argo-cd.readthedocs.io
staleness_threshold: 14d
---

# Kubernetes Specialist — Planning Mode

## When to activate
Any spec involving Kubernetes workload design, Helm chart creation, cluster operations,
GitOps setup (ArgoCD/Flux), ingress/networking, autoscaling, RBAC, or migrating
containerised workloads to Kubernetes.

## Questions to ask before designing

- Managed K8s (EKS/GKE/AKS) or self-managed? (almost always managed)
- GitOps with ArgoCD/Flux, or imperative kubectl? (GitOps for production)
- What are the resource requirements? (sets requests/limits, node sizing)
- Is there a service mesh requirement? (Istio/Linkerd for mTLS, traffic management)
- What is the ingress strategy? (Nginx, Traefik, cloud-native ALB/GCE)
- Stateful workloads? (StatefulSets, PVCs, storage class selection)

## Workload type selection

| Pattern | Resource | When |
|---------|----------|------|
| Long-running HTTP service | Deployment + HPA | Web APIs, background workers |
| Ordered, stateful service | StatefulSet | Databases, Kafka, ZooKeeper |
| One per node | DaemonSet | Log collectors (Fluentd), monitoring agents |
| Run-to-completion | Job / CronJob | Batch, scheduled tasks, DB migrations |
| Cluster-wide service | Deployment in `kube-system` | Ingress controllers, cert-manager |

## Resource requests and limits — mandatory

Every pod must have requests AND limits. Without requests: poor scheduling. Without limits: noisy neighbour kills cluster.

```yaml
resources:
  requests:
    cpu: "100m"      # 0.1 CPU — scheduler uses this for placement
    memory: "128Mi"
  limits:
    cpu: "500m"      # 0.5 CPU — throttled at this
    memory: "256Mi"  # OOMKilled if exceeded — size this generously
```

**Memory limit = hard ceiling** (OOMKill). **CPU limit = throttle** (not kill). Set memory limit ~2× memory request for headroom.

## Autoscaling

```yaml
# Horizontal Pod Autoscaler — scale on CPU or custom metrics
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**Cluster Autoscaler (or Karpenter on EKS):** Adds/removes nodes based on pending pods. Karpenter is faster and more cost-aware than Cluster Autoscaler.

## Helm — chart structure

```
mychart/
├── Chart.yaml          # metadata: name, version, appVersion
├── values.yaml         # default values
├── values-prod.yaml    # production overrides
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── _helpers.tpl    # named templates
    └── NOTES.txt
```

```bash
# Install / upgrade
helm upgrade --install myapp ./mychart -f values-prod.yaml -n myapp --create-namespace

# Dry run
helm upgrade --install myapp ./mychart --dry-run --debug

# Rollback
helm rollback myapp 1
```

**Never hardcode image tags in templates** — pass via `--set image.tag=$(git rev-parse --short HEAD)` in CI.

## GitOps with ArgoCD

```yaml
# Application manifest (declarative app definition)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/k8s-manifests
    targetRevision: main
    path: apps/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true        # delete resources removed from git
      selfHeal: true     # revert manual changes
    syncOptions:
      - CreateNamespace=true
```

**GitOps workflow:** Code PR → merge to main → ArgoCD detects diff → syncs to cluster. No manual `kubectl apply` in production.

## Networking

**Services:**
- `ClusterIP`: internal only (default)
- `NodePort`: external via node IP (dev/testing only)
- `LoadBalancer`: cloud-managed LB (production external)

**Ingress (Nginx):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [api.example.com]
      secretName: api-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 3000
```

**Network Policies:** Default-deny-all + explicit allow. Required for any production cluster handling sensitive data.

## RBAC — least privilege

```yaml
# ServiceAccount per workload — never use default SA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
---
# Role with minimum permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
kind: RoleBinding
# bind ServiceAccount to Role
```

Never use `cluster-admin` for application service accounts.

## Secrets management

```yaml
# DO NOT put secrets in plain Kubernetes Secrets committed to git
# Use External Secrets Operator to sync from AWS Secrets Manager / Vault / GCP Secret Manager
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
spec:
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: my-app-secrets
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: my-app/production
        property: database_url
```

## Health checks — mandatory for every deployment

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /health/ready
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 5

startupProbe:   # for slow-starting apps
  httpGet:
    path: /health/live
    port: 3000
  failureThreshold: 30
  periodSeconds: 10
```

## Review checklist

- [ ] All pods have resource requests AND limits defined
- [ ] HPA configured for production Deployments (min ≥ 2 replicas)
- [ ] Health probes: liveness + readiness on every container
- [ ] Dedicated ServiceAccount per workload — not default SA
- [ ] Secrets from External Secrets Operator (not plain K8s Secrets with sensitive values in git)
- [ ] Network Policies: default-deny with explicit ingress/egress rules
- [ ] GitOps: manifests in git, ArgoCD/Flux deploying — no manual kubectl apply in prod
- [ ] Non-root container user (`securityContext.runAsNonRoot: true`)
- [ ] PodDisruptionBudget for production Deployments (`minAvailable: 1`)

## Standards

Kubernetes Docs: kubernetes.io/docs
Helm Best Practices: helm.sh/docs/chart_best_practices
ArgoCD: argo-cd.readthedocs.io
Karpenter (EKS node provisioner): karpenter.sh
