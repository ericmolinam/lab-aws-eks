#!/usr/bin/env bash
# Mutates Kubernetes ONLY when explicitly invoked by an authorized operator.
set -euo pipefail
cd "$(dirname "$0")/.."
# Logical kubectl wait timeouts do not bound stalled API/credential requests.
# GNU timeout also bounds the whole process, with a five-second kill grace.
bounded_kubectl() {
  local seconds=$1
  shift
  timeout --kill-after=5s "${seconds}s" kubectl --request-timeout=30s "$@"
}
case "${1:-}" in
  up)
    bounded_kubectl 210 wait --for=condition=Ready nodepool/lab ec2nodeclass/lab --timeout=180s
    bounded_kubectl 60 apply -f manifests/karpenter/smoke.yaml
    bounded_kubectl 60 -n karpenter-smoke scale deployment/demand --replicas=2
    bounded_kubectl 630 -n karpenter-smoke rollout status deployment/demand --timeout=600s
    bounded_kubectl 60 -n karpenter-smoke get pods -o wide
    bounded_kubectl 60 get nodeclaims -l karpenter.sh/nodepool=lab
    bounded_kubectl 60 get nodes -l karpenter.sh/nodepool=lab -o wide
    ;;
  down)
    bounded_kubectl 210 delete namespace karpenter-smoke --ignore-not-found --wait=true --timeout=180s
    # Observe consolidation separately: other workloads may keep these nodes busy.
    ;;
  *) echo "Usage: $0 up|down (requires explicit deployment authorization)" >&2; exit 2 ;;
esac
