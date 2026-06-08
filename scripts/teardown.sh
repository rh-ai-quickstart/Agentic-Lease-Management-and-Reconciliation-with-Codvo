#!/usr/bin/env bash
#
# teardown.sh - Purge the NeIO LeasingOps quickstart from a cluster, cleanly.
#
# One command. Idempotent. No manual steps. Safe to re-run. Built for the
# Red Hat Demo Platform (RHDP) deprovision requirement: uninstall every Helm
# release in the namespace, then delete the namespace and wait for it to fully
# terminate (clearing stuck finalizers if the delete hangs).
#
# Usage:
#   ./scripts/teardown.sh                 # interactive confirm, namespace "leasingops"
#   ./scripts/teardown.sh -y              # no prompt (automation / RHDP)
#   ./scripts/teardown.sh -n my-ns -y     # different namespace
#   NAMESPACE=my-ns ./scripts/teardown.sh -y
#   KUBECONFIG=/path/to/cfg ./scripts/teardown.sh -y
#
# Removes, in order:
#   1. Every Helm release in the namespace (app, llamastack, llm-inference, infra).
#   2. KServe InferenceServices (the model server).
#   3. Leftover PVCs in the namespace (chart data + uploads).
#   4. The namespace itself - waits for termination, clears finalizers if stuck.
#
# Does NOT touch cluster-scoped operators (NVIDIA GPU operator, RHOAI / KServe /
# Knative) or anything outside the target namespace.

set -uo pipefail

NS="${NAMESPACE:-leasingops}"
ASSUME_YES="${FORCE:-0}"

usage() { grep '^#' "$0" | grep -v '^#!' | sed 's/^#\{1,\} \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1 ;;
    -n|--namespace)  NS="${2:?--namespace needs a value}"; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# Prefer oc (OpenShift); fall back to kubectl.
KCTL="$(command -v oc || command -v kubectl || true)"
HELM="$(command -v helm || true)"
[ -n "$KCTL" ] || { echo "ERROR: need 'oc' or 'kubectl' on PATH." >&2; exit 1; }
[ -n "$HELM" ] || { echo "ERROR: need 'helm' on PATH." >&2; exit 1; }

CTX="$($KCTL config current-context 2>/dev/null || echo unknown)"
echo "About to PURGE everything in namespace '$NS'"
echo "  context: $CTX"
echo

# Nothing to do if the namespace is already gone.
if ! $KCTL get namespace "$NS" >/dev/null 2>&1; then
  echo "Namespace '$NS' does not exist. Nothing to do."
  exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Type the namespace name '$NS' to confirm: " confirm
  [ "$confirm" = "$NS" ] || { echo "Aborted."; exit 1; }
fi

uninstall() {
  local r="$1"
  if $HELM status -n "$NS" "$r" >/dev/null 2>&1; then
    echo "  helm uninstall $r"
    $HELM uninstall -n "$NS" "$r" --wait --timeout 3m 2>/dev/null || true
  fi
}

echo "[1/4] Helm releases"
# Uninstall every release Helm knows about in this namespace, so nothing is missed...
while read -r r; do
  [ -n "$r" ] && uninstall "$r"
done < <($HELM list -n "$NS" -q 2>/dev/null)
# ...plus the known names, in case the release secret was already removed.
for r in "${RELEASE_APP:-neio-leasingops}" llamastack llm-inference "${RELEASE_INFRA:-neio-infra}"; do
  uninstall "$r"
done

echo "[2/4] KServe InferenceServices"
$KCTL delete inferenceservice --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true

echo "[3/4] PersistentVolumeClaims"
$KCTL delete pvc --all -n "$NS" --ignore-not-found 2>/dev/null || true

echo "[4/4] Namespace"
$KCTL delete namespace "$NS" --ignore-not-found --wait=false 2>/dev/null || true

echo
echo "Waiting for namespace '$NS' to terminate..."
for _ in $(seq 1 36); do
  $KCTL get namespace "$NS" >/dev/null 2>&1 || { echo "Done. Namespace '$NS' is gone."; exit 0; }
  sleep 5
done

# Stuck in Terminating (a finalizer is blocking). Clear spec.finalizers via the
# finalize subresource - the supported way to release a wedged namespace.
echo "Namespace still terminating after 3 minutes - clearing finalizers."
if command -v jq >/dev/null 2>&1; then
  $KCTL get namespace "$NS" -o json | jq '.spec.finalizers=[]' \
    | $KCTL replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true
else
  $KCTL get namespace "$NS" -o json | tr -d '\n' \
    | sed 's/"finalizers": *\[[^]]*\]/"finalizers":[]/' \
    | $KCTL replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true
fi

for _ in $(seq 1 12); do
  $KCTL get namespace "$NS" >/dev/null 2>&1 || { echo "Done. Namespace '$NS' is gone."; exit 0; }
  sleep 5
done

echo "ERROR: namespace '$NS' did not terminate. Inspect: $KCTL get namespace $NS -o yaml" >&2
exit 1
