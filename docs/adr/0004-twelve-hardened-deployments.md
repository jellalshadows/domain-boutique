# ADR-0004: twelve chart-base Deployments with the hardened defaults

- Status: accepted (design of 2026-11-03, decision 4); implemented 2026-11-16. The first kind run, PR CI run
  [43970184540](https://github.com/jellalshadows/domain-boutique/actions/runs/43970184540), proved the UID of every
  image on Kubernetes 1.33.12 and 1.37.0.

## Decision

- All 12 workloads are chart-base Deployments with chart-base's defaults: Pod Security `restricted`, UID and GID 65532,
  `seccompProfile: RuntimeDefault`, a read-only root filesystem, a token-less ServiceAccount, a PodDisruptionBudget
  and `progressDeadlineSeconds: 240`.
- The 10 services keep upstream's ports, probes, variables and resources. gRPC probes give their port by number,
  which chart-base requires from 0.12.0 (G2).
- Where upstream differs, chart-base's defaults are kept on purpose: a 30 s grace period with a 5 s preStop sleep
  instead of upstream's `terminationGracePeriodSeconds: 5` on eight Deployments (adservice, cartservice,
  currencyservice, emailservice, loadgenerator, paymentservice, productcatalogservice and recommendationservice);
  `resources` on the `frontend-check` init container, which upstream leaves unset; and the Service port name `redis`
  instead of `tcp-redis`. Pods take longer to stop. A grace period of 5 s would also need a lower
  `preStopSleepSeconds`, which chart-base requires to be shorter than the grace period.
- `redis-cart` is a Deployment with an `emptyDir` at `/data` and `strategy: Recreate`. It is ephemeral, like upstream:
  a restart empties every cart.
- `loadgenerator` has no Service. Its init container `frontend-check` runs upstream's script verbatim and gets
  `FRONTEND_ADDR` as a literal of its own: an entry's `config` (chart-base 1.2.0), the main container's value
  through a YAML anchor. An entry's `env` takes references only; up to chart-base 0.11.0 an entry had no `config`,
  so it used `inheritEnv: true` (docs/findings.md G4).
- Images are pinned by digest.
- The fallback for an image that cannot run as UID 65532 is `podSecurityContext: {runAsUser: 1000, runAsGroup: 1000,
  fsGroup: 1000}` under that alias. Which aliases use it (decision 4, "Record which"): none, since every image ran as
  65532 in the first kind run (Consequences).

## Why

- The domain is chart-base's first real test of its hardened defaults on third-party images.
- Upstream's manifests run as UID 1000 without a `seccompProfile`, so they are Pod Security `baseline`, not
  `restricted`. Every image's own user is root or empty, except cartservice's `1000`, so 1000 is no more native to them
  than 65532.

## Consequences

- Every image starts as 65532. In run
  [43970184540](https://github.com/jellalshadows/domain-boutique/actions/runs/43970184540) the 12 Deployment pods and
  the smoke pod ran as UID 65532 with `RuntimeDefault` and 0 restarts, on 1.33.12 and 1.37.0, and
  `helmfile -e ci sync` took 68 s and 59 s, well inside the 240 s progress deadline
  ([findings](../findings.md#the-first-kind-run)). The e2e keeps printing each pod's UID and restart count. A pod that
  cannot start fails the Helm wait with its events dumped; the fix is then the fallback above, recorded per alias here.
- `autoscaling` stays off: upstream has no HPA and kind has no metrics-server here.

## Evidence

- On kube-apiserver 1.33.0 and 1.37.0, a Pod built from each of the 13 pod templates (12 Deployments and the smoke
  Job) is admitted by a namespace that enforces `restricted:latest` (`kubectl create --dry-run=server`).
- The same Pod without its `seccompProfile` is rejected: `violates PodSecurity "restricted:latest": seccompProfile`.
- On kind, run [43970184540](https://github.com/jellalshadows/domain-boutique/actions/runs/43970184540) printed UID
  65532, `RuntimeDefault` and 0 restarts for all 13 pods, in a namespace enforcing `restricted`, on 1.33.12 and 1.37.0.
  The two Docker Hub images, redis-cart's `redis` and frontend-check's `busybox`, pulled anonymously on both legs.
