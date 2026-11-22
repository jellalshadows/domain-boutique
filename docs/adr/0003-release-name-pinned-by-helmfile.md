# ADR-0003: the release name is pinned by helmfile, and part of the values

- Status: accepted (design of 2026-11-03, decision 3); implemented 2026-11-16.

## Decision

- helmfile pins the release name `boutique` and the namespace `boutique`.
- A component reaches a sibling at `boutique-<alias>:<service port>`, for example
  `PRODUCT_CATALOG_SERVICE_ADDR: boutique-productcatalogservice:3550`, or `boutique-emailservice:5000` (a Service port
  over container port 8080).

## Why

- chart-base names every object `<release>-<alias>`. A subchart cannot read its siblings' values, and values are
  never templated, so the umbrella must write the release name into each address.
- This was chart-base gap [G1](../findings.md#g1-sibling-addresses-hard-code-the-release-name). From 0.12.0 chart-base
  documents it as a recipe ("Calling a sibling component" in its README), and the release name stays in the values:
  its `$(RELEASE)` form works only in `command` and `args`, and these addresses reach the containers through
  `config`.

## Consequences

- 18 addresses carry the release name: 17 in `config` and cartservice's `REDIS_ADDR` in its ExternalSecret template.
  One of the 17 is the shopping assistant's, which Online Boutique does not deploy: the frontend refuses to start
  without it.
- `helm template` under another release name succeeds and breaks every call at runtime. Guards against that:
  - `.github/scripts/check-umbrella.sh` checks that every address names a rendered Service and one of its ports;
  - `templates/NOTES.txt` warns at install under another release name.

## Evidence

- The address check passes on the deploy's render (Helm 4.3.0 and 3.22.0).
- It fails on a typo: `CART_SERVICE_ADDR=boutique-cartservice:7071 names no Service port of the render`.
- `helm template shop .` exits 0 while the frontend still calls `boutique-cartservice:7070`.
