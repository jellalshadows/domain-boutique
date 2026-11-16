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
- Adding a caller means editing both sides: its egress `toComponents` and the target's `fromComponents`.

## Evidence

- The 13 policies render as the table says (`ci/expected-objects.txt` lists them) and validate with kubeconform.
- Both API servers accept them (server dry run).
- Enforcement at runtime: only the kind e2e.
