# ADR-0006: a NetworkPolicy on every component, ingress and egress

- Status: accepted (design of 2026-11-03, decision 6); implemented 2026-11-16.

## Decision

Every component, `smoke` included, has `networkPolicy.enabled: true` with egress isolated (`egress.enabled: true`).

- **Egress:** cluster DNS plus `toComponents`, upstream's "who calls whom".
- **Ingress:** `fromComponents`, the callers.

| Component | Ingress from | Egress to (besides DNS) |
|---|---|---|
| frontend | loadgenerator, smoke, namespace `envoy-gateway-system` | productcatalog, currency, cart, recommendation, shipping, checkout, ad |
| checkoutservice | frontend | productcatalog, shipping, payment, email, currency, cart |
| recommendationservice | frontend | productcatalog |
| cartservice | frontend, checkout | redis-cart |
| productcatalogservice | frontend, checkout, recommendation | none |
| currencyservice, shippingservice | frontend, checkout | none |
| adservice | frontend | none |
| paymentservice, emailservice | checkout | none |
| redis-cart | cartservice | none |
| loadgenerator | none | frontend |
| smoke (a hook) | none | frontend |

## Why

- The call graph is the domain's strongest test of chart-base's `fromComponents` and `toComponents`.
- Upstream's own policies restrict ingress and allow all egress. Isolating egress too follows chart-base's design. No
  service calls out at start: profilers and tracing are off.

## Consequences

- kindnet enforces NetworkPolicy, and fails open when its controller cannot start. So the e2e checks a deny first:
  a pod in another namespace cannot reach `redis-cart` or the frontend.
- A `podSelector` without a `namespaceSelector` never matches another namespace, so the e2e also denies from inside
  `boutique`: a pod with a label no policy admits cannot reach `redis-cart`, and a pod with loadgenerator's selector
  labels (no owner, no Service endpoint) cannot reach a listener in `outsider` that a pod no policy selects reaches.
- The e2e places an order through the frontend, which needs checkoutservice's calls to cart, productcatalog,
  currency, shipping and payment. Its call to emailservice is best effort upstream, so no check covers that edge.
- Adding a caller means editing both sides: its egress `toComponents` and the target's `fromComponents`.

## Evidence

- The 13 policies render as the table says (`ci/expected-objects.txt` lists them) and validate with kubeconform.
- Both API servers accept them (server dry run).
- Enforcement at runtime: PR CI run
  [43970184540](https://github.com/jellalshadows/domain-boutique/actions/runs/43970184540), on kind with Kubernetes
  1.33.12 and 1.37.0. Both denies from `outsider` ended in agnhost's TIMEOUT, a dropped connection, and the allow from
  `envoy-gateway-system` passed ([findings](../findings.md#the-first-kind-run)). The checks from inside `boutique` and
  the order were added after that run; CI proves them from the next run on.
