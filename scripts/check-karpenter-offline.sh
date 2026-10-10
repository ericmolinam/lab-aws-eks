#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HELM:=helm}"
: "${TERRAFORM:=terraform}"
: "${PYTHON:=python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$TERRAFORM" fmt -check -recursive
"$TERRAFORM" init -backend=false -input=false
"$TERRAFORM" validate
"$HELM" pull oci://public.ecr.aws/karpenter/karpenter --version 1.13.0 --destination "$work"
"$HELM" pull oci://public.ecr.aws/karpenter/karpenter-crd --version 1.13.0 --destination "$work"
"$HELM" template karpenter-crd "$work/karpenter-crd-1.13.0.tgz" --namespace kube-system --include-crds > "$work/crds.yaml"
"$HELM" template karpenter "$work/karpenter-1.13.0.tgz" --namespace kube-system --skip-crds \
  -f manifests/karpenter/controller-values.yaml \
  --set settings.clusterName=dev-eks --set settings.clusterEndpoint=https://offline.example \
  --set settings.interruptionQueue=dev-eks-karpenter --set settings.eksControlPlane=true \
  --set 'controller.env[0].name=AWS_REGION' --set 'controller.env[0].value=eu-west-1' > "$work/controller.yaml"
"$HELM" lint manifests/karpenter
"$HELM" template karpenter-capacity manifests/karpenter > "$work/capacity.yaml"
# Download the release's actual IAM prerequisites for a complete policy comparison.
"$PYTHON" - "$work/official-policy.yaml" <<'PY'
import pathlib, sys, urllib.request
url = 'https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.13.0/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml'
with urllib.request.urlopen(url, timeout=30) as response:
    pathlib.Path(sys.argv[1]).write_bytes(response.read())
PY
"$PYTHON" tests/check_karpenter.py "$work"
bash -n scripts/karpenter-smoke.sh
"$PYTHON" tests/check_smoke_script.py
