# ADR-0007: two extensions, a smoke Job and a Redis password from External Secrets

- Status: accepted (design of 2026-11-03, decision 7); implemented 2026-11-16.

## Decision

1. **`smoke`, a `job` component in phase `post-deploy`.**
   - It runs agnhost 2.66.1, pinned by digest, with its curl and sh.
   - It requests the home page and the product page of `OLJCESPC7Z` (Sunglasses). Each must answer 200 with
     `<div class="hot-product-card-name">Sunglasses</div>` and `<h2>Sunglasses</h2>` respectively, or the release fails.
2. **The preferred option of the design: a Redis password.**
   - The ClusterSecretStore `boutique` holds `/boutique/redis-password`.
   - redis-cart's own ExternalSecret reads it into `boutique-redis-cart-secrets`. Its container gets `REDIS_PASSWORD`
     through `env.REDIS_PASSWORD.valueFrom.externalSecretKeyRef` (`envFrom: false`), and runs
     `redis-server --requirepass $(REDIS_PASSWORD)`.
   - cartservice's own ExternalSecret templates `REDIS_ADDR: "boutique-redis-cart:6379,password={{ .REDIS_PASSWORD }}"`
     with `mergePolicy: Replace`, injected whole.

## Why the Redis password, verified at the pinned tag

The cart service hands `REDIS_ADDR` to StackExchange.Redis as a configuration string, so a `password=` option reaches
Redis:

- `src/cartservice/src/Startup.cs:29` reads `Configuration["REDIS_ADDR"]` (environment variables included:
  `Program.cs:22`, `Host.CreateDefaultBuilder`). Lines 36-39 set it as `RedisCacheOptions.Configuration`.
- `cartservice.csproj:10` pins Microsoft.Extensions.Caching.StackExchangeRedis 10.0.11.
- In aspnetcore v10.0.11, `RedisCacheOptions.cs:64` parses it with `ConfigurationOptions.Parse(Configuration)`.
- aspnetcore v10.0.11 builds against StackExchange.Redis 2.7.27 (`eng/Versions.props:169`). Its
  `ConfigurationOptions.cs:881-896` splits the string on commas and reads `key=value`, and `password` is one of its keys
  (`:96`, `:946`).

So the value the smoke Job could check was not needed: the secret now carries real traffic.

## Why two ExternalSecrets

Each component reads its own Secret. chart-base's `externalSecretKeyRef` reads only the component's own Secret, and a
hand-written `secretKeyRef` to `boutique-redis-cart-secrets` from cartservice would hard-code a sibling's Secret name
(chart-base's `values.yaml`, `env`).

## Consequences

- The release fails unless the frontend serves both pages, which needs currency, productcatalog and cart, which needs
  Redis with the password.
- The cluster must provide a ClusterSecretStore named `boutique`: the fake provider in CI, a real one elsewhere.
- The stored password must contain no comma. StackExchange.Redis splits `REDIS_ADDR` on commas, so with `abc,def`
  cartservice would send the password `abc` and read `def` as a second endpoint, while redis-server requires
  `abc,def`. Every cart call would fail, then the home page (it reads the cart) and the smoke hook, far from the cause.
- Rotating the password needs redis-cart and cartservice restarted together. Each reads it from its environment at
  start, so restarting only one of them breaks the cart.
- The password reaches redis-server's process arguments, readable by whoever can exec into the container. The pod spec
  holds only `$(REDIS_PASSWORD)`, and the Secret holds the value.

## Evidence

- Both ExternalSecrets render as `external-secrets.io/v1` and validate with kubeconform and on both API servers.
- The e2e's Secret checks were run on objects of the same shape on both API servers: the key set `REDIS_ADDR ` and the
  decoded value.
- At runtime, PR CI run [43970184540](https://github.com/jellalshadows/domain-boutique/actions/runs/43970184540)
  proved it on kind with Kubernetes 1.33.12 and 1.37.0: both ExternalSecrets were Ready, the checks that Redis answers
  `NOAUTH Authentication required.` without the password and `PONG` with it passed, and an item added through the
  frontend was in Redis under the session's key (`EXISTS` 1). The smoke hook succeeded on both legs
  ([findings](../findings.md#the-first-kind-run)).
