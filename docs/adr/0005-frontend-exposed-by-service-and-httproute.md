# ADR-0005: the frontend is exposed by its Service; an HTTPRoute is rendered but not served

- Status: accepted (design of 2026-11-03, decision 5); implemented 2026-11-16.

## Decision

- The frontend has one Service, `boutique-frontend`, port 80, targeting container port 8080.
- An HTTPRoute is rendered: parent `boutique-gw` in namespace `gateway`, section `http`, host `boutique.example.test`.
- The frontend's NetworkPolicy admits the Gateway's proxy namespace `envoy-gateway-system`.
- No Gateway controller is installed. The e2e reaches the frontend through its Service, from a client pod in
  `envoy-gateway-system`.

## Why

- Upstream's second Service, `frontend-external` (a LoadBalancer), has no place in chart-base: one Service per alias,
  and `extraObjects` rejects a Service. The route replaces it.
- A Gateway controller is the platform's, and out of scope.

## Consequences

- CI installs the Gateway API CRDs only (`v1.6.2`, as chart-base's e2e), so the API validates the route and nothing
  serves it.
- The e2e's client pod stands for the Gateway's proxy. It proves the Service, the `fromNamespaces` rule and the pages,
  not real route traffic.
- Without a Gateway: `kubectl port-forward -n boutique service/boutique-frontend 8080:80` (`NOTES.txt`).

## Evidence

- kubeconform validates the HTTPRoute against the pinned CRD schema on Kubernetes 1.33.12 and 1.37.0.
- kube-apiserver 1.33.0 and 1.37.0 store it with the Gateway API v1.6.2 CRDs. Its backend reads
  `boutique-frontend:80`, the e2e's check.
