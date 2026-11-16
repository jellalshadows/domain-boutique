# ADR-0002: each component's configuration under its alias, one anchor for the shared label

- Status: accepted (design of 2026-11-03, decision 2); implemented 2026-11-16.

## Decision

- One `values.yaml`, with each component's whole configuration under its alias.
- `<alias>.enabled` is a real boolean on every alias. Nothing is configured through `global`.
- A root `values.schema.json` with `additionalProperties: false`: one object per alias, plus `global`. Each alias
  object requires `enabled` and allows only a boolean there.
- The one domain-wide setting, the label `domain: boutique`, is a YAML anchor. The first alias writes
  `commonLabels: &domain-labels {domain: boutique}`; the other 12 write `commonLabels: *domain-labels`.

## Why

- chart-base validates what is under an alias. Only the root schema catches a mistyped alias, which Helm would
  otherwise ignore silently.
- Helm honors only a boolean at a `condition` path: `"false"` leaves the component in the release.
- The anchor form passes `helm lint --strict` with the root schema exactly as written on both Helm versions. It needs
  no `x-` key exception and no merge key.

## Consequences

- `networkPolicy`, `probes` and `resources` stay written per alias: they differ per component, and a YAML merge is
  shallow.
- Deleting the `frontend` block would break the anchor. The YAML parser then fails at once, before any render.

## Evidence

All measured on Helm 4.3.0 and 3.22.0:

- A mistyped alias fails `helm lint`: `additional properties 'frontned' not allowed`.
- `enabled: "false"` fails it: `at '/smoke/enabled': got string, want boolean`, after Helm's "returned non-bool value"
  warning.
- The anchor forms are measured in [findings G3](../findings.md#g3-no-umbrella-wide-defaults). The chosen form renders
  identically to the repeated form.
