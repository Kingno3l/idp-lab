#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="idp-lab"

echo "Tearing down IDP Workshop environment..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Kind cluster deleted."
else
  echo "Kind cluster '${CLUSTER_NAME}' does not exist."
fi

# Clean up any lingering port-forward processes for the git server or argocd
pkill -f "kubectl port-forward.*9418" 2>/dev/null || true
pkill -f "kubectl port-forward.*8080" 2>/dev/null || true

echo "Teardown complete."
