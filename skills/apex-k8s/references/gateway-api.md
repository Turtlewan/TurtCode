# Gateway API (north-south traffic)

Load when configuring ingress/north-south routing. Gateway API is the recommended path for new
clusters; `ingress-nginx` is retired (read-only since Mar 2026, no security patches).

## GatewayClass + Gateway + HTTPRoute (Envoy Gateway shown as one example)

Envoy Gateway is used here only to make the example concrete — there is no mandated default;
pick the implementation per § Networking in `../SKILL.md` (Envoy / Cilium / Istio / cloud-native)
and set `controllerName` accordingly.

```yaml
# GatewayClass — installed with the controller (Envoy Gateway shown; swap for Cilium/Istio)
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: { name: eg }
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: app-gateway, namespace: my-app }
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: api.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - { kind: Secret, name: api-tls }   # cert-manager can populate this
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: my-app, namespace: my-app }
spec:
  parentRefs:
    - { name: app-gateway }
  hostnames: ["api.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - { name: my-app, port: 3000 }
```

cert-manager integrates with Gateway API via the `gateway-shim` (annotate the `Gateway` with
`cert-manager.io/cluster-issuer`).

## Migrating off Ingress / ingress-nginx

- `ingress-nginx` is retired — do not deploy it on new clusters; plan migration on existing ones.
- Use SIG-Network's **`ingress2gateway`** CLI to convert existing `Ingress` objects to
  `Gateway` + `HTTPRoute`, then review and apply.
- Ingress as an API is feature-frozen (not removed) — existing Ingress + a *maintained* controller
  (Traefik, cloud ALB/GCE) can stay short-term, but new design should target Gateway API.
