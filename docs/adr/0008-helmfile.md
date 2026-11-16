# ADR-0008: one helmfile release, waiting per phase, never rolling back

- Status: accepted (design of 2026-11-03, decision 8); implemented 2026-11-16 with helmfile 1.8.2.

## Decision

`helmfile.yaml` holds:

- one environment, `ci`, in its own YAML part (helmfile 1.x requires it);
- one release `boutique` in namespace `boutique`, from `chart: .` with `skipRefresh: true` and no `repositories`
  entry;
- `wait: true`, `timeout: 600`, `atomic: false` and `createNamespace: true`.

## Why

- **Local chart.** GHCR serves chart-base anonymously, and `Chart.lock` pins it. helmfile runs
  `helm dependency build . --skip-refresh`.
- **Never roll back.** On Helm 4, helmfile turns `atomic` into `--rollback-on-failure`. On a first install that
  uninstalls the whole domain, and the failing pods and their events with it.
- **Per-phase bounds.** Helm's `--timeout` applies per operation: first the wait for every Deployment, then the
  post-deploy Job's wait. The smoke Job's phase also ends earlier, at its `activeDeadlineSeconds` (180). The rollout
  phase ends earlier only on Helm 4.3: its status watcher stops at a Deployment that exceeds its
  `progressDeadlineSeconds` (240), while Helm 3's legacy wait keeps waiting until `--timeout` (chart-base's consuming
  guide). The e2e job allows 45 minutes, more than twice the worst case of 2 x 600 s.

## Consequences

- The `ci` environment changes no value. A second environment would add its own values file and a templated
  helmfile.
- A failed sync leaves the release failed in place, for diagnosis. The next sync upgrades it.

## Evidence

helmfile 1.8.2 (`helmfile -e ci ... --debug`, against an unreachable cluster) runs, on Helm 4.3.0 and 3.22.0 alike:

```console
helm dependency build . --skip-refresh
helm upgrade --install boutique . --wait --timeout 600s --create-namespace --namespace boutique --reset-values --history-max 10
```

With `atomic: true` the same command gains `--rollback-on-failure` on Helm 4.3.0 and `--atomic` on Helm 3.22.0.

`helmfile -e ci template` renders exactly `helm template boutique . --namespace boutique` on both versions.
`helmfile -e ci lint` passes on both.
