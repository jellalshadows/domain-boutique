#!/usr/bin/env bash
# Static checks of the umbrella that neither helm lint nor kubeconform makes, on the deploy's real render (release
# boutique, namespace boutique, every component enabled):
#   1. every chart-base dependency has one version and one repository URL, and each alias is toggled by <alias>.enabled;
#   2. the rendered objects are exactly ci/expected-objects.txt (kind/name): a renamed alias or release fails here;
#   3. every sibling address a component is given (a ConfigMap value or an ExternalSecret template of the form
#      <host>:<port>) names a rendered Service and one of its ports: the release name is part of the values
#      (docs/findings.md G1), and a typo in an address renders without error and fails only at runtime.
# Usage: check-umbrella.sh <umbrella-dir>     Requires: helm (dependencies built), yq (mikefarah v4)
set -euo pipefail

dir="${1:?usage: check-umbrella.sh <umbrella-dir>}"
cd "$dir"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== chart-base dependencies"
yq -e '[.dependencies[]|select(.name=="chart-base")|.version]|unique|length==1' Chart.yaml > /dev/null \
  || fail "every chart-base alias must use one version, found: $(yq -o=json -I=0 '[.dependencies[]|select(.name=="chart-base")|.version]|unique' Chart.yaml)"
yq -e '[.dependencies[]|select(.name=="chart-base")|.repository]|unique|length==1' Chart.yaml > /dev/null \
  || fail "every chart-base alias must use one repository URL, found: $(yq -o=json -I=0 '[.dependencies[]|select(.name=="chart-base")|.repository]|unique' Chart.yaml)"
bad="$(yq '[.dependencies[]|select(.condition != .alias + ".enabled")|.alias]|join(" ")' Chart.yaml)"
[ -z "$bad" ] || fail "each alias must be toggled by condition <alias>.enabled, these are not: $bad"
pass "one chart-base version ($(yq '.dependencies[0].version' Chart.yaml)) and one repository URL for $(yq '.dependencies|length' Chart.yaml) aliases, each toggled by <alias>.enabled"

echo "== rendered objects"
helm template boutique . --namespace boutique -f ci/all-enabled.yaml > "$work/rendered.yaml"
yq -N '.kind + "/" + .metadata.name' "$work/rendered.yaml" | LC_ALL=C sort > "$work/objects.txt"
if ! diff -u ci/expected-objects.txt "$work/objects.txt" > "$work/objects.diff"; then
  printf '%s\n' "$(< "$work/objects.diff")" >&2
  fail "the rendered objects differ from ci/expected-objects.txt (diff above: - expected, + rendered)"
fi
pass "the $(wc -l < "$work/objects.txt" | tr -d ' ') rendered objects are exactly ci/expected-objects.txt"

echo "== sibling addresses"
# Every <service>:<port> a Service of the render serves.
yq -N 'select(.kind == "Service") | .metadata.name + ":" + (.spec.ports[].port | tostring)' "$work/rendered.yaml" \
  > "$work/served.txt"
declare -A served=()
while read -r s; do served[$s]=1; done < "$work/served.txt"
# Every value of the components' ConfigMaps and ExternalSecret templates that starts with <host>:<port>; a
# StackExchange.Redis configuration string carries options after a comma.
yq -N '(select(.kind == "ConfigMap") | .metadata.name + " " + (.data | to_entries[] | .key + " " + .value)),
  (select(.kind == "ExternalSecret") | .metadata.name + " " + (.spec.target.template.data // {} | to_entries[] | .key + " " + .value))' \
  "$work/rendered.yaml" > "$work/values.txt"
# The frontend needs an address for the shopping assistant, which Online Boutique's release does not deploy.
not_deployed="boutique-shoppingassistantservice:80"
checked=0
while read -r object key value; do
  address="${value%%,*}"
  [[ "$address" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?:[0-9]+$ ]] || continue
  checked=$((checked + 1))
  [ "$address" = "$not_deployed" ] && continue
  [ -n "${served[$address]:-}" ] \
    || fail "$object: $key=$address names no Service port of the render (served: ${!served[*]})"
done < "$work/values.txt"
# 18: the frontend's 8, checkoutservice's 6, one each for recommendationservice, loadgenerator, smoke and cartservice's
# REDIS_ADDR. A lower count means an address this check no longer sees.
[ "$checked" = 18 ] || fail "expected 18 sibling addresses in the render, found $checked: $(tr '\n' ';' < "$work/values.txt")"
pass "the $checked sibling addresses name a rendered Service and port (but $not_deployed, not deployed)"
