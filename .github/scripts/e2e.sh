#!/usr/bin/env bash
# The boutique domain on a fresh kind cluster, deployed as helmfile deploys it:
#   the platform: Gateway API CRDs (no controller; the bundle checked against GATEWAY_API_SHA256), External Secrets
#   Operator with a fake ClusterSecretStore named boutique, and the namespace boutique enforcing Pod Security
#   "restricted";
#   the deploy: helmfile -e ci sync (Helm waits for every Deployment, then runs the post-deploy smoke Job);
#   the checks: every Deployment available, the smoke Job succeeded, the home page and a product page through the
#   frontend's Service, an add to cart end to end (frontend -> cartservice -> redis-cart, read back from Redis), an
#   order placed through the frontend (checkoutservice and its callees), both ExternalSecrets Ready and their value in
#   use (Redis refuses a client without the password), and NetworkPolicy enforced (a pod of another namespace cannot
#   reach redis-cart or the frontend, the Gateway's namespace can; a pod of the namespace that no policy admits cannot
#   reach redis-cart; a pod that loadgenerator's policy selects cannot reach outside its egress).
# It refuses a kube context whose name does not start with kind- (it installs an operator, creates namespaces and
# overwrites the ClusterSecretStore boutique); E2E_ALLOW_ANY_CONTEXT=1 runs it on the current context anyway. Its setup
# steps can run again on the same cluster.
# On any failure, a check or an unguarded command, it prints what it found, then the namespace's objects, events, pods
# and logs.
# Usage: e2e.sh <umbrella-dir>     Requires: kubectl, helm, helmfile, curl, sha256sum
# Env: GATEWAY_API_VERSION (e.g. v1.6.2), GATEWAY_API_SHA256 (the sha256 of that release's standard-install.yaml),
#      ESO_CHART_VERSION (e.g. 2.11.0)
set -Eeuo pipefail

dir="${1:?usage: e2e.sh <umbrella-dir>}"
: "${GATEWAY_API_VERSION:?}" "${GATEWAY_API_SHA256:?}" "${ESO_CHART_VERSION:?}"
ns=boutique
# The frontend's NetworkPolicy admits the Gateway's proxy pods from this namespace (values.yaml): the client pod of the
# checks stands for them. No Gateway controller is installed (docs/adr/0005-frontend-exposed-by-service-and-httproute.md).
gw_ns=envoy-gateway-system
# A namespace that no policy of the domain admits.
out_ns=outsider
agnhost="registry.k8s.io/e2e-test-images/agnhost:2.66.1@sha256:6e2eef87d0dc77e070a7549bc5fdfa290c0fefe3359eb33c2ad1eda692fe66a4"
# The fake store's value: no comma (StackExchange.Redis splits its configuration string on commas).
redis_password=boutique-e2e-redis-pw
frontend="http://boutique-frontend.$ns.svc.cluster.local"
product_id=OLJCESPC7Z
product_name=Sunglasses

context="$(kubectl config current-context 2> /dev/null || true)"
if [[ "$context" != kind-* ]] && [ "${E2E_ALLOW_ANY_CONTEXT:-}" != 1 ]; then
  echo "FAIL: the kube context is '$context', not a kind cluster's (kind-*); set E2E_ALLOW_ANY_CONTEXT=1 to run on it anyway" >&2
  exit 1
fi

dumped=false
dump() {
  # Once: a failed check and the ERR trap never both dump.
  $dumped && return 0
  dumped=true
  echo "== diagnostics" >&2
  kubectl get all,externalsecrets,networkpolicies,httproutes,serviceaccounts,configmaps,secrets -n "$ns" -o wide >&2 || true
  kubectl get events -n "$ns" --sort-by=.lastTimestamp >&2 || true
  # A pod stuck in Init, ContainerCreating (a Secret not synced yet) or CrashLoopBackOff (a UID the image cannot run
  # as) shows why in its description.
  kubectl describe pods -n "$ns" >&2 || true
  for d in $(kubectl get deployments -n "$ns" -o name 2> /dev/null || true); do
    kubectl logs -n "$ns" "$d" --all-containers --prefix --tail=80 >&2 || true
    kubectl logs -n "$ns" "$d" --all-containers --prefix --previous --tail=40 >&2 || true
  done
  kubectl logs -n "$ns" job/boutique-smoke --tail=80 >&2 || true
  kubectl describe externalsecrets -n "$ns" >&2 || true
  kubectl get clustersecretstore boutique -o yaml >&2 || true
  kubectl logs -n external-secrets deploy/external-secrets --tail=100 >&2 || true
  kubectl get pods -n "$gw_ns" -o wide >&2 || true
  kubectl get pods -n "$out_ns" -o wide >&2 || true
  # kindnet enforces NetworkPolicy and logs when it cannot.
  kubectl logs -n kube-system ds/kindnet --tail=100 >&2 || true
}
fail() {
  echo "FAIL: $*" >&2
  dump
  exit 1
}
# A command that fails outside a check fails the run too, with the same dump (set -E: inside functions as well). In a
# command substitution's subshell the trap stands aside and leaves the failure to the command that uses its output.
on_error() {
  local status="$1" line="$2" command="$3"
  [ "$BASHPID" = "$$" ] || return "$status"
  echo "FAIL: line $line: '$command' exited $status" >&2
  dump
  exit "$status"
}
pass() { echo "ok - $*"; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ensure_namespace <name>: creates the namespace, or leaves an existing one as it is.
ensure_namespace() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -; }
# agnhost_pod <namespace> <name> <agnhost arguments...>: a fresh agnhost pod, Ready (a leftover of an earlier run is
# deleted first).
agnhost_pod() {
  local pod_ns="$1" name="$2"
  shift 2
  kubectl delete pod -n "$pod_ns" "$name" --ignore-not-found --now
  kubectl run "$name" -n "$pod_ns" --image="$agnhost" --restart=Never -- "$@"
  kubectl wait -n "$pod_ns" "pod/$name" --for=condition=Ready --timeout=120s || fail "the pod $pod_ns/$name did not become Ready"
}
# restricted_pod <name> <labels, a YAML flow mapping>: a fresh agnhost pod in $ns, Ready, with the securityContext that
# Pod Security "restricted" requires. A bare pod: no controller owns it.
restricted_pod() {
  local name="$1" labels="$2"
  kubectl delete pod -n "$ns" "$name" --ignore-not-found --now
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels: $labels
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: agnhost
      image: $agnhost
      args: [pause]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
EOF
  kubectl wait -n "$ns" "pod/$name" --for=condition=Ready --timeout=120s || fail "the pod $ns/$name did not become Ready"
}

echo "== platform"
echo "kube context $context; kind nodes: $(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion} {.items[*].status.nodeInfo.containerRuntimeVersion}' || true)"
echo "helm $(helm version --short), helmfile $(helmfile --version 2>&1 | tr '\n' ' ')"
# Only the CRDs: the frontend's HTTPRoute must be accepted by the API, nothing serves it. The bundle must have the sha256
# pinned next to its version (the workflow's env).
bundle="$work/gateway-api-standard-install.yaml"
curl -fsSL -o "$bundle" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  || fail "could not download the Gateway API $GATEWAY_API_VERSION bundle"
bundle_sha="$(sha256sum "$bundle" | cut -d ' ' -f 1)"
[ "$bundle_sha" = "$GATEWAY_API_SHA256" ] \
  || fail "the Gateway API $GATEWAY_API_VERSION standard-install.yaml must have the sha256 $GATEWAY_API_SHA256 (GATEWAY_API_SHA256), got $bundle_sha"
kubectl apply --server-side -f "$bundle"
helm upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version "$ESO_CHART_VERSION" --namespace external-secrets --create-namespace --wait --timeout 5m \
  || fail "External Secrets Operator $ESO_CHART_VERSION did not install or become ready in 5 minutes"
# The store the umbrella's ExternalSecrets name; elsewhere a real provider backs it.
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: boutique
spec:
  provider:
    fake:
      data:
        - key: /boutique/redis-password
          value: $redis_password
EOF
kubectl wait clustersecretstore/boutique --for=condition=Ready --timeout=120s \
  || fail "the ClusterSecretStore boutique did not become Ready in 120 s"
ensure_namespace "$ns"
kubectl label namespace "$ns" --overwrite \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
# The check pods of an earlier run that failed (the NetworkPolicy checks delete theirs once they pass): the impersonator
# carries loadgenerator's labels.
kubectl delete pod -n "$ns" intruder impersonator --ignore-not-found --now
pass "platform: Gateway API CRDs $GATEWAY_API_VERSION (sha256 checked), External Secrets $ESO_CHART_VERSION with the store boutique, namespace $ns enforcing restricted"

echo "== helmfile -e ci sync"
start=$SECONDS
(cd "$dir" && helmfile -e ci sync) \
  || fail "helmfile -e ci sync failed after $((SECONDS - start)) s: a Deployment not available within the timeout, or the smoke Job (see its log below)"
pass "helmfile -e ci sync succeeded in $((SECONDS - start)) s (every Deployment available, then the post-deploy smoke Job)"

echo "== workloads"
want="boutique-adservice=1/1 boutique-cartservice=1/1 boutique-checkoutservice=1/1 boutique-currencyservice=1/1 boutique-emailservice=1/1 boutique-frontend=1/1 boutique-loadgenerator=1/1 boutique-paymentservice=1/1 boutique-productcatalogservice=1/1 boutique-recommendationservice=1/1 boutique-redis-cart=1/1 boutique-shippingservice=1/1 "
got="$(kubectl get deployments -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}={.status.availableReplicas}/{.spec.replicas} {end}' || true)"
[ "$got" = "$want" ] || fail "every Deployment must have its one replica available (name=available/desired), got '$got'"
pass "the 12 Deployments each have their replica available"
# For the record (decision 4: the UID each image runs as, and whether a container restarted while its siblings started).
kubectl get pods -n "$ns" -o custom-columns='POD:.metadata.name,UID:.spec.securityContext.runAsUser,SECCOMP:.spec.securityContext.seccompProfile.type,RESTARTS:.status.containerStatuses[*].restartCount,PHASE:.status.phase'
# For the record: Helm's wait already required the loadgenerator to be available, so this cannot fail on its own.
check="$(kubectl get pods -n "$ns" -l app.kubernetes.io/name=loadgenerator -o jsonpath='{.items[0].status.initContainerStatuses[?(@.name=="frontend-check")].state.terminated.exitCode}' || true)"
[ "$check" = 0 ] || fail "the loadgenerator's init container frontend-check (inheritEnv, egress to the frontend) must have exited 0, got '$check'"
pass "the loadgenerator's init container frontend-check exited 0 (recorded: Helm's wait already required it)"
# For the record: the API returns the HTTPRoute as Helm applied it.
route="$(kubectl get httproute -n "$ns" boutique-frontend -o jsonpath='{.spec.rules[0].backendRefs[0].name}:{.spec.rules[0].backendRefs[0].port}' || true)"
[ "$route" = boutique-frontend:80 ] || fail "the HTTPRoute must be stored with the backend boutique-frontend:80, got '$route'"
pass "the HTTPRoute is stored with the backend boutique-frontend:80 (recorded: as rendered; no controller serves it)"

echo "== smoke Job (post-deploy hook)"
smoke="$(kubectl get job -n "$ns" boutique-smoke -o jsonpath='{.status.succeeded}' || true)"
[ "$smoke" = 1 ] || fail "the post-deploy Job boutique-smoke must have succeeded once, got succeeded '$smoke'"
kubectl logs -n "$ns" job/boutique-smoke > "$work/smoke.log" || fail "could not read the smoke Job's log"
last="$(tail -n 1 "$work/smoke.log")"
[ "$last" = smoke-ok ] || fail "the smoke Job's last log line must be smoke-ok, got '$last'"
left="$(kubectl get networkpolicy,configmap,serviceaccount -n "$ns" boutique-smoke boutique-smoke-env --ignore-not-found -o name)" \
  || fail "could not look up the smoke Job's hook resources (a kubectl error, not their absence)"
[ -z "$left" ] || fail "the smoke Job's NetworkPolicy, ConfigMap and ServiceAccount are hooks deleted once it succeeded, found: $(printf '%s' "$left" | tr '\n' ' ')"
pass "the smoke Job succeeded (home page and product page, 200 with '$product_name'), its hook resources are gone"

echo "== the frontend through its Service"
ensure_namespace "$gw_ns"
agnhost_pod "$gw_ns" client pause
# fetch <file> <curl arguments...>: an HTTP request from the client pod; prints the status, the body goes to <file>.
fetch() {
  local file="$1"
  shift
  kubectl exec -n "$gw_ns" client -- curl -sS --max-time 10 -o /tmp/body -w '%{http_code}' "$@" || return 1
  kubectl exec -n "$gw_ns" client -- cat /tmp/body > "$file"
}
code="$(fetch "$work/home.html" "$frontend/" || true)"
[ "$code" = 200 ] || fail "GET $frontend/ must answer 200, got '$code'"
grep -qF "<div class=\"hot-product-card-name\">$product_name</div>" "$work/home.html" \
  || fail "the home page must list the product $product_name, the body begins: $(head -c 400 "$work/home.html")"
code="$(fetch "$work/product.html" "$frontend/product/$product_id" || true)"
[ "$code" = 200 ] || fail "GET $frontend/product/$product_id must answer 200, got '$code'"
grep -qF "<h2>$product_name</h2>" "$work/product.html" \
  || fail "the product page must title $product_name, the body begins: $(head -c 400 "$work/product.html")"
pass "the home page and the product page answer 200 with '$product_name' through the Service boutique-frontend"

echo "== add to cart (frontend -> cartservice -> redis-cart)"
session="e2e-$(date +%s)-$RANDOM"
code="$(fetch "$work/add.html" -X POST -H "Cookie: shop_session-id=$session" -d "product_id=$product_id" -d quantity=2 "$frontend/cart" || true)"
[ "$code" = 302 ] || fail "POST /cart must redirect (302) once the item is stored, got '$code', the body begins: $(head -c 400 "$work/add.html")"
code="$(fetch "$work/cart.html" -H "Cookie: shop_session-id=$session" "$frontend/cart" || true)"
[ "$code" = 200 ] || fail "GET /cart must answer 200, got '$code'"
grep -qF "SKU #$product_id" "$work/cart.html" || fail "the cart must hold SKU #$product_id, the body begins: $(head -c 400 "$work/cart.html")"
grep -qF "Quantity: 2" "$work/cart.html" || fail "the cart must hold the quantity 2, the body begins: $(head -c 400 "$work/cart.html")"
# The cart service stores a cart as a Redis hash keyed by the session id; read it with the container's own password.
# shellcheck disable=SC2016 # expanded by the container's shell
stored="$(kubectl exec -n "$ns" deploy/boutique-redis-cart -c redis-cart -- sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli EXISTS "$1"' sh "$session" 2>&1 || true)"
[ "$stored" = 1 ] || fail "Redis must hold the cart of the session $session (EXISTS 1), got '$stored'"
pass "an item added through the frontend is in the cart page and in Redis under the session's key"

echo "== place an order (frontend -> checkoutservice -> cart, productcatalog, currency, shipping, payment, email)"
# Upstream v0.10.7 (commit 5b608cb):
#   - placeOrderHandler reads these form fields (src/frontend/handlers.go:325-334); the values are the defaults of the
#     checkout form (src/frontend/templates/cart.html:114-206), with next year's expiry so the card is valid;
#   - the order page says "Your order is complete!" (src/frontend/templates/order.html:33);
#   - checkoutservice fails the order when the cart, the catalog, currency, payment or shipping fails, but only logs a
#     failed confirmation email (src/checkoutservice/main.go:238-274): the page does not prove the edge to emailservice.
code="$(fetch "$work/order.html" -X POST -H "Cookie: shop_session-id=$session" \
  --data-urlencode email=someone@example.com --data-urlencode "street_address=1600 Amphitheatre Parkway" \
  --data-urlencode zip_code=94043 --data-urlencode "city=Mountain View" --data-urlencode state=CA \
  --data-urlencode "country=United States" --data-urlencode credit_card_number=4432801561520454 \
  --data-urlencode credit_card_expiration_month=1 --data-urlencode "credit_card_expiration_year=$(($(date +%Y) + 1))" \
  --data-urlencode credit_card_cvv=672 "$frontend/cart/checkout" || true)"
[ "$code" = 200 ] || fail "POST /cart/checkout must answer 200 with the order page, got '$code', the body begins: $(head -c 400 "$work/order.html")"
grep -qF "Your order is complete!" "$work/order.html" \
  || fail "the order page must say 'Your order is complete!', the body begins: $(head -c 400 "$work/order.html")"
pass "an order placed through the frontend answers 200 with 'Your order is complete!'"

echo "== ExternalSecrets"
kubectl wait -n "$ns" externalsecret/boutique-redis-cart-secrets externalsecret/boutique-cartservice-secrets \
  --for=condition=Ready --timeout=120s || fail "both ExternalSecrets must be Ready"
keys="$(kubectl get secret -n "$ns" boutique-cartservice-secrets -o go-template="{{range \$k, \$v := .data}}{{\$k}} {{end}}" || true)"
[ "$keys" = "REDIS_ADDR " ] || fail "cartservice's Secret must hold REDIS_ADDR only (mergePolicy Replace), got keys '$keys'"
addr="$(kubectl get secret -n "$ns" boutique-cartservice-secrets -o jsonpath='{.data.REDIS_ADDR}' | base64 -d || true)"
[ "$addr" = "boutique-redis-cart:6379,password=$redis_password" ] \
  || fail "cartservice's REDIS_ADDR must be the templated configuration string with the store's password, got '${addr%%password=*}password=<redacted>' (length ${#addr})"
ref="$(kubectl get deployment -n "$ns" boutique-redis-cart -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REDIS_PASSWORD")].valueFrom.secretKeyRef.name}' || true)"
[ "$ref" = boutique-redis-cart-secrets ] || fail "redis-cart's REDIS_PASSWORD must reference its own Secret boutique-redis-cart-secrets, got '$ref'"
noauth="$(kubectl exec -n "$ns" deploy/boutique-redis-cart -c redis-cart -- redis-cli PING 2>&1 || true)"
[ "$noauth" = "NOAUTH Authentication required." ] || fail "Redis must refuse a client without the password (--requirepass), got '$noauth'"
# shellcheck disable=SC2016 # expanded by the container's shell
pong="$(kubectl exec -n "$ns" deploy/boutique-redis-cart -c redis-cart -- sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli PING' 2>&1 || true)"
[ "$pong" = PONG ] || fail "Redis must answer PONG with the password of its Secret, got '$pong'"
pass "both ExternalSecrets are Ready; Redis requires the store's password, and the cart service's REDIS_ADDR carries it"

echo "== NetworkPolicy"
# agnhost connect reports a dropped connection as TIMEOUT and a port where nothing listens as REFUSED; a DNS error
# never counts as either. kindnet fails open: the deny checks come first (chart-base's e2e.sh).
# probe allow|deny <namespace> <pod> <host:port>: polls every second for up to 10 s, 3 s per attempt.
probe() {
  local expect="$1" from_ns="$2" from="$3" to="$4" out got deadline=$((SECONDS + 10))
  while :; do
    if out="$(kubectl exec -n "$from_ns" "$from" -- /agnhost connect "$to" --timeout=3s 2>&1)"; then
      got=allow
    else
      case "$out" in
        *REFUSED*) got=allow ;;
        *TIMEOUT*) got=deny ;;
        *) got="error: $out" ;;
      esac
    fi
    [ "$got" = "$expect" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  echo "probe $from_ns/$from -> $to: expected $expect, got $got" >&2
  return 1
}
ensure_namespace "$out_ns"
agnhost_pod "$out_ns" probe pause
probe deny "$out_ns" probe "boutique-redis-cart.$ns.svc.cluster.local:6379" \
  || fail "a pod of another namespace must not reach redis-cart (its policy admits cartservice only)"
probe deny "$out_ns" probe "boutique-frontend.$ns.svc.cluster.local:80" \
  || fail "a pod of another namespace must not reach the frontend (its policy admits loadgenerator, smoke and $gw_ns)"
probe allow "$gw_ns" client "boutique-frontend.$ns.svc.cluster.local:80" \
  || fail "the Gateway's namespace $gw_ns must reach the frontend (fromNamespaces)"
pass "NetworkPolicy is enforced: another namespace reaches neither redis-cart nor the frontend, $gw_ns reaches the frontend"

# Inside the namespace. A podSelector without a namespaceSelector never matches another namespace, so the denies above
# would still pass if a policy admitted every pod of $ns, or if egress isolation stopped rendering. chart-base selects a
# component's pods by app.kubernetes.io/name and app.kubernetes.io/instance (chart-base.selectorLabels), in its
# NetworkPolicy's podSelector and in its Service's selector alike:
#   - intruder: a label that no policy selects or admits, so its own traffic is not restricted;
#   - impersonator: loadgenerator's selector labels, so loadgenerator's policy isolates its egress (DNS and the
#     frontend only). loadgenerator has no Service, and its ReplicaSet also selects pod-template-hash, so the pod is no
#     Service's endpoint and no ReplicaSet adopts it (both checked below);
#   - listener: agnhost netexec in $out_ns, which no policy covers: a target that is reachable unless a policy drops it.
selector="$(kubectl get networkpolicy -n "$ns" boutique-loadgenerator -o go-template='{{len .spec.podSelector.matchLabels}} {{index .spec.podSelector.matchLabels "app.kubernetes.io/name"}} {{index .spec.podSelector.matchLabels "app.kubernetes.io/instance"}}' || true)"
[ "$selector" = "2 loadgenerator boutique" ] \
  || fail "loadgenerator's NetworkPolicy must select exactly app.kubernetes.io/name=loadgenerator and app.kubernetes.io/instance=boutique (the impersonator's labels), got '$selector' (count name instance)"
agnhost_pod "$out_ns" listener netexec --http-port=8080
listener="$(kubectl get pod -n "$out_ns" listener -o jsonpath='{.status.podIP}' || true)"
[ -n "$listener" ] || fail "the listener pod $out_ns/listener has no IP"
restricted_pod intruder '{app.kubernetes.io/name: intruder}'
restricted_pod impersonator '{app.kubernetes.io/name: loadgenerator, app.kubernetes.io/instance: boutique}'
probe deny "$ns" intruder "boutique-redis-cart.$ns.svc.cluster.local:6379" \
  || fail "a pod of $ns that no policy admits must not reach redis-cart (its policy admits cartservice only)"
probe deny "$ns" impersonator "$listener:8080" \
  || fail "a pod that loadgenerator's NetworkPolicy selects must not reach $out_ns/listener (its egress allows DNS and the frontend only)"
# The control of the egress deny: the same target, from a pod that no policy selects. TIMEOUT above means the policy.
probe allow "$ns" intruder "$listener:8080" \
  || fail "a pod that no policy selects must reach $out_ns/listener at $listener:8080, or the egress deny proves nothing"
probe allow "$ns" impersonator "boutique-frontend.$ns.svc.cluster.local:80" \
  || fail "a pod that loadgenerator's NetworkPolicy selects must reach the frontend (its toComponents)"
owners="$(kubectl get pod -n "$ns" impersonator -o jsonpath='{.metadata.ownerReferences}')" \
  || fail "could not read the pod $ns/impersonator"
[ -z "$owners" ] || fail "no controller may adopt the impersonator pod, got the owners $owners"
endpoints="$(kubectl get endpointslices -n "$ns" -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name} {end}')" \
  || fail "could not list the EndpointSlices of $ns"
case " $endpoints" in
  *" intruder "* | *" impersonator "*) fail "the check pods must be no Service's endpoint, the EndpointSlices of $ns list: $endpoints" ;;
esac
pass "NetworkPolicy inside $ns: a pod no policy admits cannot reach redis-cart; a pod that loadgenerator's policy selects (no owner, no Service) cannot reach $out_ns/listener, which a pod no policy selects reaches"
kubectl delete pod -n "$ns" intruder impersonator --now
kubectl delete pod -n "$out_ns" probe listener --now
kubectl delete pod -n "$gw_ns" client --now

# For the record: the load generator's traffic (Locust prints its request statistics).
kubectl logs -n "$ns" deploy/boutique-loadgenerator -c loadgenerator --tail=15 || true

echo "e2e: all checks passed"
