#!/usr/bin/env bash
# Mutates Kubernetes ONLY when explicitly invoked by an authorized operator.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  up)
    kubectl wait --for=condition=Ready nodepool/lab ec2nodeclass/lab --timeout=180s
    kubectl apply -f manifests/karpenter/smoke.yaml
    kubectl -n karpenter-smoke scale deployment/demand --replicas=2
    kubectl -n karpenter-smoke rollout status deployment/demand --timeout=600s
    kubectl -n karpenter-smoke get pods -o wide
    kubectl get nodeclaims -l karpenter.sh/nodepool=lab
    kubectl get nodes -l karpenter.sh/nodepool=lab -o wide
    ;;
  down)
    kubectl delete namespace karpenter-smoke --ignore-not-found --wait=true --timeout=180s
    # Observe consolidation separately: other workloads may keep these nodes busy.
    ;;
  *) echo "Usage: $0 up|down (requires explicit deployment authorization)" >&2; exit 2 ;;
esac
