#!/usr/bin/env bash
#
# teardown.sh - Tears down the NeIO LeasingOps quickstart deployment.
#
# Use this between demo runs to reset the cluster to a clean state.
# Idempotent: safe to run even if some resources don't exist.
#
# Usage:
#   ./scripts/teardown.sh                     # uses your current oc context
#   KUBECONFIG=/path/to/cfg ./scripts/teardown.sh
#
# What it removes:
#   - The neio-leasingops Helm release
#   - The llamastack Helm release
#   - The llm-inference Helm release (vLLM + KServe InferenceService)
#   - The standalone Postgres + Redis manifests
#   - All Secrets in the leasingops namespace
#   - The leasingops namespace itself
#
# It does NOT touch:
#   - The NVIDIA GPU operator
#   - RHOAI / KServe / Knative
#   - The ACR pull secret in your local files (~/Downloads/redhat-partner-*.json)

set -u

NS="${NAMESPACE:-leasingops}"

echo "Tearing down namespace: $NS"
echo

uninstall() {
  local release="$1"
  if helm status -n "$NS" "$release" >/dev/null 2>&1; then
    echo "  helm uninstall $release"
    helm uninstall -n "$NS" "$release" --wait --timeout 2m || true
  else
    echo "  $release not installed, skipping"
  fi
}

echo "[1/5] Helm releases"
uninstall neio-leasingops
uninstall llamastack
uninstall llm-inference

echo
echo "[2/5] InferenceServices (KServe)"
oc delete inferenceservice -n "$NS" --all --wait=false 2>/dev/null || true

echo
echo "[3/5] Standalone Postgres + Redis"
oc delete -f /tmp/leasingops-data-services.yaml --ignore-not-found 2>/dev/null || true
oc delete deployment postgresql redis -n "$NS" --ignore-not-found 2>/dev/null || true
oc delete service neio-leasingops-postgresql redis -n "$NS" --ignore-not-found 2>/dev/null || true

echo
echo "[4/5] PVCs and Secrets"
oc delete pvc --all -n "$NS" --ignore-not-found 2>/dev/null || true
oc delete secret neio-leasingops-secrets acr-pull-secret -n "$NS" --ignore-not-found 2>/dev/null || true

echo
echo "[5/5] Namespace"
oc delete project "$NS" --ignore-not-found 2>/dev/null || true

echo
echo "Waiting for namespace to fully terminate..."
for i in $(seq 1 30); do
  if ! oc get ns "$NS" >/dev/null 2>&1; then
    echo "Done. Namespace $NS is gone."
    exit 0
  fi
  sleep 5
done

echo "Namespace $NS is still terminating after 2.5 minutes."
echo "Check with: oc get ns $NS -o yaml"
exit 1
