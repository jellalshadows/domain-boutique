#!/usr/bin/env bash
# Renders the umbrella as helmfile deploys it (release boutique, namespace boutique, every component enabled) and
# validates the manifests with kubeconform against Kubernetes' strict schemas and pinned CRD schemas (Gateway API's
# HTTPRoute, External Secrets' ExternalSecret). The schema sources are chart-base's (its validate-manifests.sh).
# Usage: validate-manifests.sh <umbrella-dir> <kubernetes-version, e.g. 1.33.12>
# Requires: helm (dependencies built), kubeconform
set -euo pipefail

dir="${1:?usage: validate-manifests.sh <umbrella-dir> <k8s-version>}"
kube_version="${2:?usage: validate-manifests.sh <umbrella-dir> <k8s-version>}"

# Pinned schema sources (bump deliberately, with chart-base's).
k8s_schemas="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/a6f9a32d2ccb64b6e4f5b41419b9c2e8ee0cce18/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
crd_schemas="https://raw.githubusercontent.com/datreeio/CRDs-catalog/ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

echo "== boutique (Kubernetes $kube_version)"
helm template boutique "$dir" --namespace boutique --kube-version "$kube_version" -f "$dir/ci/all-enabled.yaml" \
  | kubeconform -strict -summary \
      -kubernetes-version "$kube_version" \
      -schema-location "$k8s_schemas" \
      -schema-location "$crd_schemas"
