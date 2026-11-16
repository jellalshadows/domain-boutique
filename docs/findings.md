# chart-base gaps found by the boutique umbrella

This umbrella is the first real domain built on chart-base 0.11.0, and it validates chart-base's 1.0 criterion 2.
Every gap it revealed is listed here with its evidence, for chart-base's 1.0 preparation. chart-base itself is not
changed from this repository.

## Summary

| ID | Gap | Class | Severity | Where the umbrella works around it |
|---|---|---|---|---|
| [G1](#g1-sibling-addresses-hard-code-the-release-name) | Sibling addresses hard-code the release name, in `config` and in an ExternalSecret template | docs | medium | helmfile pins the release name; CI checks every address |
| [G2](#g2-a-main-container-probe-port-is-not-checked) | A main-container probe takes a port name where Kubernetes needs a number | chart (breaking to fix) | medium | ten gRPC probes by number |
| [G3](#g3-no-umbrella-wide-defaults) | No umbrella-wide defaults | consumer workaround | low | a YAML anchor |
| [G4](#g4-an-init-container-has-no-literal-env) | An init container has no literal `env` | consumer workaround | low | `config` plus `inheritEnv: true` |
| [G5](#g5-online-boutique-exercises-the-deployment-path-only) | Online Boutique exercises the Deployment path only | scope of criterion 2 | medium | the smoke Job and the Redis password |
| [G6](#g6-appkubernetesiocomponent-holds-the-workload-type) | `app.kubernetes.io/component` holds the workload type | observation | low | none |
| [G7](#g7-no-recipe-for-a-secret-on-the-command-line) | No recipe for a secret on the command line | docs | low | `$(REDIS_PASSWORD)` from an `env` entry |
| [G8](#g8-the-version-label-comes-from-the-tag-even-when-a-digest-pins-the-image) | The version label comes from the tag even when a digest pins the image | observation | low | a versioned tag next to the digest |

Severity reads as chart-base's: **medium** should be settled before the 1.0 contract freeze, **low** can follow it.

## How the evidence was produced

- Locally, on 2026-11-16, from the repository root, with Helm 4.3.0 and Helm 3.22.0, kubeconform 0.8.0, and the envtest
  kube-apiservers 1.33.0 and 1.37.0 (no controllers, no kubelet).
- chart-base 0.11.0 came from `oci://ghcr.io/jellalshadows/charts` (digest
  `sha256:3fac6ea218c81758d58d5441497336f7547d68bede2e3e3642f6d03058a18bea`).
- chart-base file references are at its `main` = `50c4f1c`.
- The feasibility research (2026-11-03) found G1 to G6. Its probe renders are cited where this run did not repeat them.

## G1: sibling addresses hard-code the release name

**What happens.** chart-base names every object `<release>-<alias>` (`templates/_names.tpl:12-14`). A subchart cannot
read its siblings' values, and values are never templated. So the umbrella writes each address with the release name
in it: 18 of them (`CART_SERVICE_ADDR: boutique-cartservice:7070`, ...). cartservice's ExternalSecret template carries
one too: `REDIS_ADDR: "boutique-redis-cart:6379,password={{ .REDIS_PASSWORD }}"`.

Under another release name, the render succeeds, the Services are renamed, and every address still points at
`boutique-*`. The frontend would answer `/_healthz` while every page fails.

```console
$ helm template shop . --namespace boutique -f ci/all-enabled.yaml     # Helm 4.3.0 and 3.22.0: exit 0
ConfigMap shop-frontend-env:            CART_SERVICE_ADDR=boutique-cartservice:7070
Services:                               shop-adservice shop-cartservice shop-checkoutservice ...
ExternalSecret shop-cartservice-secrets: REDIS_ADDR=boutique-redis-cart:6379,password={{ .REDIS_PASSWORD }}
```

**Workaround here.**

- `helmfile.yaml` pins the release name `boutique` and the namespace `boutique`.
- `.github/scripts/check-umbrella.sh` checks that each of the 18 addresses names a rendered Service and port. A typo
  fails it:

  ```console
  FAIL: boutique-frontend-env: CART_SERVICE_ADDR=boutique-cartservice:7071 names no Service port of the render
  ```

- `templates/NOTES.txt` warns when the release is not `boutique`.

**Candidate fix (docs, additive).** A consuming-guide section and a README recipe, "calling a sibling component":

- the address is `<release>-<alias>:<servicePort>`, `<name>.<namespace>.svc` across namespaces;
- pin the release name in helmfile;
- the same applies to an ExternalSecret template.

A chart feature, such as a placeholder resolved in `config`, would break "values as written". Decide it explicitly.

## G2: a main-container probe port is not checked

**What happens.** The main container's probes are open Kubernetes objects. A gRPC probe whose port is a name renders,
and passes `helm lint --strict`. kubeconform rejects it, and so does the API server at install time. A gRPC domain
writes ten such probes (`values.yaml`: every service except frontend and redis-cart).

```console
$ helm template boutique . -f ci/all-enabled.yaml -f g2.yaml   # g2.yaml: adservice readiness grpc: {port: grpc}
exit 0 (Helm 4.3.0 and 3.22.0); helm lint --strict: exit 0
$ kubeconform -strict ... (Kubernetes 1.33.12)
Deployment boutique-adservice is invalid: ... at '/spec/template/spec/containers/0/readinessProbe/grpc/port': got string, want integer
$ kubectl apply --server-side --dry-run=server ...             # kube-apiserver 1.33.0 and 1.37.0
.spec.template.spec.containers[name="adservice"].readinessProbe.grpc.port: expected numeric (int or float), got string
```

**Workaround here.** Every gRPC probe gives its port by number. kubeconform runs in CI on both Kubernetes versions.

**Candidate fix.** Close the main container's probes like a sidecar's (`definitions.probe`), which chart-base's roadmap
already lists for the 1.0 freeze (`docs/roadmap.md:91`). Closing them later is breaking, so this is the real case that
justifies doing it at the freeze.

## G3: no umbrella-wide defaults

**What happens.** `global` is not read, by design (`docs/guides/consuming.md:99-102`). So a domain-wide setting, here the
label `domain: boutique`, is written under all 13 aliases. Settings that differ per alias inside one map, such as
`networkPolicy`, cannot be shared by a YAML merge, which is shallow.

**Measured.** Every anchor form renders and passes `helm lint --strict -f ci/all-enabled.yaml` on both Helm versions,
provided the root schema allows its keys. The renders are identical to the repeated form.

| Form | Helm 4.3.0 | Helm 3.22.0 |
|---|---|---|
| top-level `x-boutique: &boutique` and `<<: *boutique`, root schema `additionalProperties: false` | exit 1: `additional properties 'x-boutique' not allowed` | exit 1, the same error |
| the same, no root schema | exit 0 | exit 0 |
| the same, root schema with `patternProperties: {"^x-": {}}` | exit 0 | exit 0 |
| the first alias anchors its labels (`&domain-labels`), the others alias them (`*domain-labels`) | exit 0 | exit 0 |
| a merge key, then an alias overrides a merged key | exit 0 (the override wins) | exit 0 |

This corrects the 2026-09-27 reading that "Helm 4's strict lint rejects top-level `x-` keys and merge-key overrides".
The `x-` key is rejected by the umbrella's root schema, on both Helm versions alike. A merge-key override passes.

**Workaround here.** The fourth form (`values.yaml`, under `frontend.commonLabels`). It needs no exception in the root
schema.

**Candidate fix (docs).** An anchors recipe in the consuming guide, next to its root-schema recommendation
(`docs/guides/consuming.md:798-802`): anchor on the first alias, or allow `^x-` in the root schema.

## G4: an init container has no literal `env`

**What happens.** Upstream's `frontend-check` init container sets `FRONTEND_ADDR` as a literal. In chart-base, an
entry's `env` takes references only:

```console
$ helm template boutique . -f ci/all-enabled.yaml -f g4.yaml   # frontend-check.env.FRONTEND_ADDR: boutique-frontend:80
Error: execution error at (boutique/charts/loadgenerator/templates/validate.yaml:539:4): chart-base[loadgenerator]:
initContainers.frontend-check.env.FRONTEND_ADDR is a literal value: env takes valueFrom references only; pass literals
in args, or put them in the component's config and set inheritEnv: true
```

**Workaround here.** The component's `config` plus `inheritEnv: true`, which the error message itself proposes
(`values.yaml`, `loadgenerator.initContainers.frontend-check`).

**Candidate fix.** The roadmap's "entry-level `config`" (`docs/roadmap.md:64-67`) now has a second real case. It is
additive and can follow 1.0.

## G5: Online Boutique exercises the Deployment path only

**What happens.** The demo has no Job, CronJob, secret, metrics or RBAC.

**Addressed in part (decision 7).** Two extensions now exercise more of the chart:

- a `job` component as a `post-deploy` hook: the `smoke` Job, with its hook ConfigMap, ServiceAccount and NetworkPolicy;
- ExternalSecrets read two ways: `env.<NAME>.valueFrom.externalSecretKeyRef` with `envFrom: false` (redis-cart), and a
  `template` with `mergePolicy: Replace` injected whole (cartservice).

**Still unexercised by a real umbrella.** CronJob, KEDA, `metrics`/`prometheusRule`, `rbac`, `sidecars`, `configFiles`,
`extraObjects`. chart-base's own e2e covers each of them. Whether that is enough for criterion 2 is the owner's call.

## G6: `app.kubernetes.io/component` holds the workload type

**What happens.** `templates/_labels.tpl:19` writes `app.kubernetes.io/component: {{ .Values.workload.type }}`. Every
object of the 12 Deployments says `deployment`, and the smoke Job's say `job`. Kubernetes' recommended labels define
`component` as the component within the architecture (here `cartservice`, `frontend`...), which chart-base puts in
`app.kubernetes.io/name`.

**Candidate fix.** Decide before the 1.0 label freeze whether that is intended. It is not a selector label, so changing
it rolls pods but does not break a Deployment.

## G7: no recipe for a secret on the command line

**What happens.** Redis takes its password as a flag (`--requirepass`). chart-base has no setting for that and needs
none: the kubelet expands `$(NAME)` in `command` and `args` from the container's environment. So redis-cart writes:

- `args: ["--requirepass", "$(REDIS_PASSWORD)"]`;
- `env.REDIS_PASSWORD.valueFrom.externalSecretKeyRef: {key: REDIS_PASSWORD}`, rendered as a `secretKeyRef` on
  `boutique-redis-cart-secrets`.

The guides never show this. They also do not warn that a `command` script's `$(...)` is the kubelet's syntax too: an
unresolved name is left as written, and `$$` is an escape.

**Evidence.** The rendered container: `args: [--requirepass, $(REDIS_PASSWORD)]` with
`env[REDIS_PASSWORD].valueFrom.secretKeyRef.name: boutique-redis-cart-secrets`. The API servers accept it (server dry
run, both versions). The expansion itself is Kubernetes' documented behavior and is proven at runtime only by the kind
e2e: Redis must answer `NOAUTH` without the password and `PONG` with it.

**Candidate fix (docs).** A README recipe, "a secret as a command-line flag", next to `externalSecretKeyRef`.

## G8: the version label comes from the tag even when a digest pins the image

**What happens.** `app.kubernetes.io/version` is the image tag. A digest pins what runs, and the tag stays only for
the label. With upstream's floating `redis:alpine`, every redis-cart object was labelled `app.kubernetes.io/version:
"alpine"`, which names no version.

The tag also moved after the digest was taken. On 2026-11-03 `alpine` named the pinned build `sha256:21090af9...`
(Redis 8.10.3). On 2026-11-16 `alpine` and `8.10.3-alpine` both name `sha256:7958cfbb...`.

**Workaround here.** `tag: 8.10.3-alpine` next to the digest, so the label names the version that runs.

**Candidate fix (docs).** The README's image section: with a digest, keep the tag the version you pinned, because only
the label reads it.

## Observations outside chart-base

These are recorded for the first kind run and for whoever maintains this umbrella, not as chart-base gaps.

- **amd64 only.** Every Online Boutique image is a single-architecture `linux/amd64` manifest (research §1). CI runs on
  amd64 runners only.
- **Docker Hub.** `redis` and `busybox` come from Docker Hub. Its anonymous pull limits on shared runner IPs are
  unverified. Both are pinned by digest, and both digests are older than their tags today (research §1, and G8 here).
- **helmfile 1.x.** It refuses `environments` and `releases` in one YAML part (`environments and releases cannot be
  defined within the same YAML part`): `helmfile.yaml` separates them with `---`.
