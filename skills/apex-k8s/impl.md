---
skill: apex-k8s
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# Kubernetes — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Use `latest` image tag in production manifests — always pin to a digest or semver tag
- Run containers as root — set `runAsNonRoot: true` and `runAsUser: 1000`
- Use the `default` ServiceAccount for application workloads
- Store secrets in plain Kubernetes Secrets committed to git (base64 ≠ encrypted)
- Skip resource requests/limits — scheduling and stability depend on them
- Use `kubectl apply -f` directly in production — use GitOps (ArgoCD/Flux)

ALWAYS:
- Set `requests` AND `limits` on every container
- Add `readinessProbe` and `livenessProbe` to every container
- Use `PodDisruptionBudget` for production Deployments
- Set `minReplicas: 2` (or more) in HPA for production
- Annotate `kubectl.kubernetes.io/last-applied-configuration` is handled by server-side apply

## Deployment — production template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
  labels:
    app: my-app
    version: "1.0.0"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0   # zero-downtime
  template:
    metadata:
      labels:
        app: my-app
    spec:
      serviceAccountName: my-app   # dedicated SA, not default
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: myregistry.io/myapp:1.0.0   # never use 'latest'
          ports:
            - containerPort: 3000
              protocol: TCP

          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"

          readinessProbe:
            httpGet:
              path: /health/ready
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /health/live
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3

          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: my-app-secrets
                  key: database-url
            - name: NODE_ENV
              value: "production"

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - mountPath: /tmp
              name: tmp-dir   # writable tmp for readOnlyRootFilesystem

      volumes:
        - name: tmp-dir
          emptyDir: {}

      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: my-app
```

## HPA + PodDisruptionBudget

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app
  namespace: my-app
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
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5 min before scaling down
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app
  namespace: my-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

## External Secrets Operator

```yaml
# ClusterSecretStore (configured once per cluster)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets

---
# ExternalSecret — per namespace
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: my-app-secrets
    creationPolicy: Owner
  data:
    - secretKey: database-url
      remoteRef:
        key: myapp/production
        property: database_url
    - secretKey: jwt-secret
      remoteRef:
        key: myapp/production
        property: jwt_secret
```

## Helm chart — values.yaml pattern

```yaml
# values.yaml
image:
  repository: myregistry.io/myapp
  tag: ""    # overridden in CI: --set image.tag=$(git rev-parse --short HEAD)
  pullPolicy: IfNotPresent

replicaCount: 2

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70

ingress:
  enabled: true
  className: nginx
  host: api.example.com
  tls: true
  certIssuer: letsencrypt-prod

serviceAccount:
  create: true
  name: ""    # defaults to release name
```

## kubectl — daily commands

```bash
# Context management
kubectl config get-contexts
kubectl config use-context prod-cluster

# Deploy from local manifest
kubectl apply -f k8s/ --server-side

# Rolling restart (picks up new secret values)
kubectl rollout restart deployment/my-app -n my-app

# Watch rollout progress
kubectl rollout status deployment/my-app -n my-app

# Debug a crashing pod
kubectl describe pod -l app=my-app -n my-app
kubectl logs -l app=my-app -n my-app --previous   # logs from crashed container

# Exec into a running pod
kubectl exec -it deployment/my-app -n my-app -- /bin/sh

# Port-forward for local testing
kubectl port-forward service/my-app 3000:3000 -n my-app

# Check resource usage
kubectl top pods -n my-app
kubectl top nodes

# Helm install / upgrade
helm upgrade --install my-app ./charts/my-app \
  -f values-prod.yaml \
  --set image.tag=$(git rev-parse --short HEAD) \
  -n my-app \
  --create-namespace

# ArgoCD sync
argocd app sync my-app
argocd app wait my-app --health
```

## Network Policy — default deny + explicit allow

```yaml
# Deny all ingress/egress by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: my-app
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Allow ingress from nginx ingress controller only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
  namespace: my-app
spec:
  podSelector:
    matchLabels:
      app: my-app
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
  policyTypes:
    - Ingress
---
# Allow DNS egress (required for all pods)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: my-app
spec:
  podSelector: {}
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
  policyTypes:
    - Egress
```

## Verification checklist

- [ ] All containers have `requests` and `limits` defined
- [ ] `readinessProbe` and `livenessProbe` on every container
- [ ] Containers run as non-root (`runAsNonRoot: true`, `runAsUser: 1000`)
- [ ] `readOnlyRootFilesystem: true` with `emptyDir` for `/tmp`
- [ ] `allowPrivilegeEscalation: false`, all capabilities dropped
- [ ] Dedicated ServiceAccount per workload (not `default`)
- [ ] Secrets via External Secrets Operator — not plain K8s Secrets with sensitive values in git
- [ ] HPA with `minReplicas ≥ 2` in production
- [ ] PodDisruptionBudget with `minAvailable: 1`
- [ ] Network Policies: default-deny with explicit allow rules
- [ ] Image tag pinned to digest or semver (never `latest` in prod)
- [ ] Deployed via ArgoCD/GitOps — no manual `kubectl apply` in production
