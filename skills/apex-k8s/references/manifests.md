# Kubernetes production manifests

Load when authoring workload manifests. All examples are cloud-agnostic; cloud-specific bits
(ESO backend, LoadBalancer annotations) are noted inline.

## Deployment — production template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
  labels: { app: my-app, version: "1.0.0" }
spec:
  replicas: 2
  selector:
    matchLabels: { app: my-app }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }   # zero-downtime
  template:
    metadata:
      labels: { app: my-app }
    spec:
      serviceAccountName: my-app   # dedicated SA, not default
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: myregistry.io/myapp:1.0.0   # never 'latest'; pin digest/semver
          ports:
            - { containerPort: 3000, protocol: TCP }
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          readinessProbe:
            httpGet: { path: /health/ready, port: 3000 }
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /health/live, port: 3000 }
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3
          # startupProbe for slow starters: same httpGet, failureThreshold: 30, periodSeconds: 10
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: my-app-secrets, key: database-url }
            - { name: NODE_ENV, value: "production" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { mountPath: /tmp, name: tmp-dir }   # writable tmp for readOnlyRootFilesystem
      volumes:
        - { name: tmp-dir, emptyDir: {} }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: my-app }
```

### Native sidecar (GA 1.33)

A sidecar (log shipper, proxy, mesh) is an **init container with `restartPolicy: Always`** — it
starts before app containers and stops after them, fixing the old ordering races:

```yaml
spec:
  template:
    spec:
      initContainers:
        - name: log-shipper
          image: myregistry.io/log-shipper:1.0.0
          restartPolicy: Always        # <- makes this a native sidecar
          # ...resources, securityContext as above
```

## HPA + PodDisruptionBudget

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: my-app, namespace: my-app }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: my-app }
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 300 }   # wait 5 min before scaling down
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: my-app, namespace: my-app }
spec:
  minAvailable: 1
  selector:
    matchLabels: { app: my-app }
```

**VPA + in-place resize (GA 1.35):** a VPA with `updatePolicy.updateMode: InPlaceOrRecreate`
right-sizes `requests` without restarting the pod where the runtime supports it. Use VPA for
right-sizing and HPA for replica count — don't drive both off CPU simultaneously.

## External Secrets Operator (API `v1`)

```yaml
# ClusterSecretStore (once per cluster) — AWS example; swap provider for Vault/GCP
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: aws-secretsmanager }
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef: { name: external-secrets, namespace: external-secrets }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: my-app-secrets, namespace: my-app }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secretsmanager, kind: ClusterSecretStore }
  target: { name: my-app-secrets, creationPolicy: Owner }
  data:
    - secretKey: database-url
      remoteRef: { key: myapp/production, property: database_url }
    - secretKey: jwt-secret
      remoteRef: { key: myapp/production, property: jwt_secret }
```

## RBAC — least privilege

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: my-app }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: my-app }
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: my-app }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: my-app }
subjects:
  - { kind: ServiceAccount, name: my-app }
```

Never bind `cluster-admin` to an application ServiceAccount.

## Argo CD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: my-app, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/k8s-manifests
    targetRevision: main
    path: apps/my-app
  destination: { server: https://kubernetes.default.svc, namespace: my-app }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

## Helm — values.yaml pattern

```yaml
image:
  repository: myregistry.io/myapp
  tag: ""    # overridden in CI: --set image.tag=$(git rev-parse --short HEAD)
  pullPolicy: IfNotPresent
replicaCount: 2
resources:
  requests: { cpu: "100m", memory: "128Mi" }
  limits:   { cpu: "500m", memory: "256Mi" }
autoscaling: { enabled: true, minReplicas: 2, maxReplicas: 20, targetCPUUtilizationPercentage: 70 }
gateway:                          # north-south via Gateway API (see gateway-api.md)
  enabled: true
  host: api.example.com
  tls: true
serviceAccount: { create: true, name: "" }   # defaults to release name
```

```bash
helm upgrade --install myapp ./mychart -f values-prod.yaml \
  --set image.tag=$(git rev-parse --short HEAD) -n myapp --create-namespace
helm upgrade --install myapp ./mychart --dry-run --debug   # dry run
helm rollback myapp 1                                       # rollback
```

## Network Policy — default deny + explicit allow

```yaml
# Deny all ingress/egress by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all, namespace: my-app }
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
# Allow ingress from the gateway/ingress controller namespace only
# (swap the label to match your controller, e.g. envoy-gateway-system / ingress-nginx / istio-system)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-from-gateway, namespace: my-app }
spec:
  podSelector:
    matchLabels: { app: my-app }
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: envoy-gateway-system }
  policyTypes: ["Ingress"]
---
# Allow DNS egress (required for all pods)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: my-app }
spec:
  podSelector: {}
  egress:
    - ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
  policyTypes: ["Egress"]
```
