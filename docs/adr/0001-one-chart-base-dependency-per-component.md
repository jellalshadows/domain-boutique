# ADR-0001: one chart-base dependency per component

- Status: accepted (design of 2026-11-03, decision 1); implemented 2026-11-16.

## Decision

- The umbrella chart `boutique` sits at the repository root.
- Each workload is one dependency on `chart-base` `1.6.1` (`0.11.0` until 2026-11-23) from
  `oci://ghcr.io/jellalshadows/charts`, with `alias: <component>` and `condition: <component>.enabled`. That makes 13:
  the 12 Online Boutique workloads and `smoke`.
- `Chart.lock` is committed; `charts/*.tgz` is git-ignored and rebuilt by `helm dependency build`.
- The umbrella is not published: no release-please, no OCI push. CI validates it and helmfile deploys it.

## Why

- Helm's named templates are global across an umbrella's subcharts. Two chart-base versions in one umbrella collide,
  so every alias pins one version and one repository URL (chart-base's consuming guide, "Rules").
- Publishing has no consumer: the domain is deployed from this repository.

## Consequences

- CI checks the rule with the spec's `yq -e '[.dependencies[]|select(.name=="chart-base")|.version]|unique|length==1'`.
  `.github/scripts/check-umbrella.sh` also checks the repository URL and that each condition is `<alias>.enabled`.
- Moving to a new chart-base version changes all 13 entries and `Chart.lock` together. The move from 0.11.0 to 1.6.1
  followed chart-base's upgrade guide. Its one change that applies here: chart-base stopped writing
  `app.kubernetes.io/component` in 0.12.0, so the 12 Deployments rolled once. The umbrella also adopted the fix of its
  gap G4 ([docs/findings.md](../findings.md#status-at-chart-base-161)).

## Evidence

- `helm dependency build .` pulls chart-base 1.6.1 anonymously on Helm 4.3.0 and 3.22.0. The pull prints the digest
  that chart-base published for 1.6.1, `sha256:e754d2209d8b868530429a0451ee9803b4ef60507d3639fea32920b531189a50`.
- A second version on one alias fails the check: `FAIL: every chart-base alias must use one version, found:
  ["0.11.0","0.10.0"]`.
- A condition other than `<alias>.enabled` fails it: `FAIL: each alias must be toggled by condition <alias>.enabled,
  these are not: smoke`.
