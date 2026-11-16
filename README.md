# domain-boutique

Google's [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) v0.10.7, deployed as a domain
umbrella of [chart-base](https://github.com/jellalshadows/chart-base) 0.11.0. It runs 12 workloads and a smoke Job,
one chart-base alias each, configured with values alone, and deploys with helmfile.

This repository is how chart-base 1.0 gets validated: its criterion 2 asks for a real domain umbrella deployed with
helmfile. What the umbrella revealed about chart-base is in [docs/findings.md](docs/findings.md).

## Quick path: run it on kind

You need an amd64 machine (the Online Boutique images are `linux/amd64` only), kind, kubectl, curl, Helm 4.3.0 (or
3.22.0) and helmfile 1.8.2 or later. CI uses kind v0.32.0 (Kubernetes 1.33.12) and v0.33.0 (1.37.0), whose kindnet
enforces NetworkPolicy. Run it on a fresh kind cluster:

```console
kind create cluster --name boutique
GATEWAY_API_VERSION=v1.6.2 GATEWAY_API_SHA256=faede450fa178126aba41337737b97d351ebe87d93c910237ce1e072d1ca40d9 \
  ESO_CHART_VERSION=2.11.0 .github/scripts/e2e.sh .
```

`e2e.sh` refuses a kube context whose name does not start with `kind-`, because it installs an operator, creates
namespaces and overwrites the ClusterSecretStore `boutique`. `E2E_ALLOW_ANY_CONTEXT=1` runs it on the current context
anyway. Its setup steps can run again on the same cluster.

[`e2e.sh`](.github/scripts/e2e.sh) is what CI runs, in three steps:

1. **Platform.** It provides what the domain expects from a cluster:
   - the Gateway API CRDs;
   - External Secrets Operator with a ClusterSecretStore named `boutique` (the fake provider holds
     `/boutique/redis-password`);
   - the namespace `boutique`, enforcing Pod Security `restricted`.
2. **Deploy.** It runs `helmfile -e ci sync`.
3. **Checks.** It checks the result end to end.

On a cluster that already has that platform, the deploy alone is:

```console
helmfile -e ci sync
kubectl port-forward -n boutique service/boutique-frontend 8080:80   # then open http://localhost:8080
```

The release name must stay `boutique`: components call each other as `boutique-<alias>`
([ADR-0003](docs/adr/0003-release-name-pinned-by-helmfile.md)).

## Components

| Alias | What it is | Port (Service -> container) | Calls | Called by |
|---|---|---|---|---|
| `frontend` | Go web UI | `http` 80 -> 8080 | productcatalog, currency, cart, recommendation, shipping, checkout, ad | loadgenerator, smoke, the Gateway's namespace |
| `checkoutservice` | Go, places orders | `grpc` 5050 | productcatalog, shipping, payment, email, currency, cart | frontend |
| `cartservice` | .NET, carts in Redis | `grpc` 7070 | redis-cart | frontend, checkout |
| `productcatalogservice` | Go, the catalog | `grpc` 3550 | none | frontend, checkout, recommendation |
| `currencyservice` | Node.js | `grpc` 7000 | none | frontend, checkout |
| `recommendationservice` | Python | `grpc` 8080 | productcatalog | frontend |
| `shippingservice` | Go | `grpc` 50051 | none | frontend, checkout |
| `paymentservice` | Node.js | `grpc` 50051 | none | checkout |
| `emailservice` | Python | `grpc` 5000 -> 8080 | none | checkout |
| `adservice` | Java | `grpc` 9555 | none | frontend |
| `redis-cart` | Redis 8.10.3, ephemeral, password from External Secrets | `redis` 6379 | none | cartservice |
| `loadgenerator` | Locust, no Service; an init container waits for the frontend | none | frontend | none |
| `smoke` | post-deploy Job: the home page and a product page must answer 200 | none | frontend | none |

Every component has a NetworkPolicy matching this table, plus DNS egress.

## How it is built

| Decision | Record |
|---|---|
| One chart-base 0.11.0 dependency per component, `Chart.lock` committed, never published | [ADR-0001](docs/adr/0001-one-chart-base-dependency-per-component.md) |
| Each component's configuration under its alias; a root schema; one YAML anchor for the shared label | [ADR-0002](docs/adr/0002-values-under-each-alias.md) |
| The release name `boutique` is part of the values; helmfile pins it | [ADR-0003](docs/adr/0003-release-name-pinned-by-helmfile.md) |
| Twelve Deployments on chart-base's hardened defaults (Pod Security `restricted`, UID 65532) | [ADR-0004](docs/adr/0004-twelve-hardened-deployments.md) |
| The frontend through its Service; an HTTPRoute rendered, not served | [ADR-0005](docs/adr/0005-frontend-exposed-by-service-and-httproute.md) |
| A NetworkPolicy on every component, ingress and egress | [ADR-0006](docs/adr/0006-networkpolicy-on-every-component.md) |
| Two extensions: a post-deploy smoke Job, and a Redis password from External Secrets | [ADR-0007](docs/adr/0007-smoke-job-and-redis-password-extensions.md) |
| One helmfile release, waiting per phase, never rolling back | [ADR-0008](docs/adr/0008-helmfile.md) |

## CI

[`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) runs on every pull request, on amd64 runners.

- **Static checks**, on Helm 4.3.0 and 3.22.0:
  - `helm dependency build`;
  - the one-version check;
  - `helm lint --strict` with [every component enabled](ci/all-enabled.yaml);
  - [`check-umbrella.sh`](.github/scripts/check-umbrella.sh): every rendered name against
    [`ci/expected-objects.txt`](ci/expected-objects.txt), and every sibling address against the rendered Services;
  - kubeconform on Kubernetes 1.33.12 and 1.37.0.
- **e2e on kind** 1.33 and 1.37, node images pinned by digest. [`e2e.sh`](.github/scripts/e2e.sh) checks:
  - every Deployment available, and the smoke hook succeeded;
  - the home page and a product page through the frontend's Service;
  - an item added to the cart, read back from Redis, then an order placed through the frontend;
  - both ExternalSecrets Ready, and Redis refusing a client without the password;
  - NetworkPolicy denials: a pod of another namespace, a pod of `boutique` that no policy admits, and the egress of a
    pod that loadgenerator's policy selects.

  On any failure it dumps events, pods and logs.
- **Repository lint:** actionlint, shellcheck, zizmor, and an offline Markdown link check.

To update a pinned version, edit:

- the workflow: its `env` block (with `GATEWAY_API_SHA256` next to `GATEWAY_API_VERSION`), the Helm 3 entry of the
  static matrix, the kind matrix (kind versions and node image digests), and zizmor's `version:`;
- `Chart.yaml` and `Chart.lock` (with `helm dependency update`);
- an image digest in `values.yaml`. The agnhost digest is in two places: the smoke Job in `values.yaml`, and
  `e2e.sh`;
- the schema commits in [`validate-manifests.sh`](.github/scripts/validate-manifests.sh).

Then run the static checks locally. Besides Helm, they need `yq` (mikefarah v4) and kubeconform 0.8.0:

```console
helm dependency build . && helm lint --strict . -f ci/all-enabled.yaml
.github/scripts/check-umbrella.sh . && .github/scripts/validate-manifests.sh . 1.33.12
```

## License

Apache-2.0, like chart-base. Online Boutique's images are Google's, under their own Apache-2.0 license.
