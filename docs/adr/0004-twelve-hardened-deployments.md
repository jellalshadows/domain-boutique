# ADR-0004: twelve chart-base Deployments with the hardened defaults

- Status: accepted (design of 2026-11-03, decision 4); implemented 2026-11-16. The UID of each image is proven only by
  the first kind run.

## Decision

- All 12 workloads are chart-base Deployments with chart-base's defaults: Pod Security `restricted`, UID and GID 65532,
  `seccompProfile: RuntimeDefault`, a read-only root filesystem, a token-less ServiceAccount, a PodDisruptionBudget
  and `progressDeadlineSeconds: 240`.
- The 10 services keep upstream's ports, probes, variables and resources. gRPC probes give their port by number.
- `redis-cart` is a Deployment with an `emptyDir` at `/data` and `strategy: Recreate`. It is ephemeral, like upstream:
  a restart empties every cart.
- `loadgenerator` has no Service. Its init container `frontend-check` runs upstream's script verbatim and gets
  `FRONTEND_ADDR` through `inheritEnv: true`.
- Images are pinned by digest.
- The fallback for an image that cannot run as UID 65532 is `podSecurityContext: {runAsUser: 1000, runAsGroup: 1000,
  fsGroup: 1000}` under that alias. No alias uses it yet.

## Why

- The domain is chart-base's first real test of its hardened defaults on third-party images.
- Upstream's manifests run as UID 1000 without a `seccompProfile`, so they are Pod Security `baseline`, not
  `restricted`. Every image's own user is root or empty, except cartservice's `1000`, so 1000 is no more native to them
  than 65532.

## Consequences

- Whether each image starts as 65532 is unknown until kind. The e2e prints each pod's UID and restart count, and a pod
  that cannot start fails the Helm wait with its events dumped. The fix is the fallback above, recorded per alias here.
- `autoscaling` stays off: upstream has no HPA and kind has no metrics-server here.

## Evidence

- On kube-apiserver 1.33.0 and 1.37.0, a Pod built from each of the 13 pod templates (12 Deployments and the smoke
  Job) is admitted by a namespace that enforces `restricted:latest` (`kubectl create --dry-run=server`).
- The same Pod without its `seccompProfile` is rejected: `violates PodSecurity "restricted:latest": seccompProfile`.
