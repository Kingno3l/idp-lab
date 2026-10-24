#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="idp-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REQUIRED_IMAGES=(
  "quay.io/argoproj/argocd:v2.12.3"
  "redis:7.0-alpine"
  "alpine/git:latest"
  "nginx:1.25-alpine"
)

echo "=========================================================="
echo "    IDP Workshop Environment Automated Setup              "
echo "=========================================================="

echo "[1/8] Verifying prerequisite CLI tools..."
for cmd in docker kind kubectl git; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done
echo "✓ All CLI tools detected."

echo "[2/8] Pre-caching container images on host..."
for img in "${REQUIRED_IMAGES[@]}"; do
  echo "  - Pulling $img..."
  docker pull "$img" >/dev/null 2>&1 || true
done
echo "✓ Images cached."

echo "[3/8] Creating kind cluster '${CLUSTER_NAME}'..."
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "  - Removing existing cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/manifests/kind-config.yaml"

echo "[4/8] Side-loading images directly into kind (eliminates Wi-Fi bottleneck)..."
for img in "${REQUIRED_IMAGES[@]}"; do
  echo "  - Loading $img into kind..."
  kind load docker-image "$img" --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
done
echo "✓ In-cluster images ready."

echo "[5/8] Installing Argo CD..."
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml >/dev/null

echo "  - Exposing Argo CD server via NodePort 30080 -> hostPort 8080..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 8080, "nodePort": 30080}]}}' >/dev/null
kubectl patch deployment argocd-server -n argocd --type json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]' >/dev/null

echo "  - Waiting for Argo CD components (up to 5m)..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s

echo "[6/8] Deploying in-cluster Git server..."
kubectl apply -f "${SCRIPT_DIR}/manifests/git-server.yaml" >/dev/null
kubectl rollout status deployment/git-server -n git-system --timeout=120s

echo "[7/8] Seeding Git repository with Sync Wave manifests..."
kubectl port-forward svc/git-server -n git-system 9418:9418 >/dev/null 2>&1 &
PF_PID=$!

# Wait for port-forward to be responsive
for i in {1..15}; do
  if nc -z 127.0.0.1 9418 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/9418) 2>/dev/null; then
    break
  fi
  sleep 1
done

TMP_GIT=$(mktemp -d)
(
  cd "$TMP_GIT"
  git init -b main >/dev/null 2>&1
  mkdir -p apps
  cp "${SCRIPT_DIR}"/manifests/apps/*.yaml apps/
  git config user.email "workshop@idp-lab.local"
  git config user.name "IDP Workshop"
  git add .
  git commit -m "feat: initial commit with sync waves" >/dev/null 2>&1
  git remote add origin git://127.0.0.1:9418/repo.git
  git push -u origin main --force >/dev/null 2>&1
)
rm -rf "$TMP_GIT"
kill "$PF_PID" 2>/dev/null || true

echo "[8/8] Applying Argo CD Application & Waiting for Sync..."
kubectl apply -f "${SCRIPT_DIR}/manifests/argocd-app.yaml" >/dev/null

echo "  - Waiting for tenant workloads to reconcile..."
for i in {1..30}; do
  if kubectl get deployment edge-gateway -n tenant-core >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl rollout status deployment/redis-store -n tenant-core --timeout=120s
kubectl rollout status deployment/edge-gateway -n tenant-core --timeout=120s

ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "=========================================================="
echo "    ✓ IDP Workshop Environment Ready!                     "
echo "=========================================================="
echo " Dashboard URL : http://localhost:8080"
echo " Username      : admin"
echo " Password      : ${ADMIN_PASS}"
echo "=========================================================="
echo "You are staged at Phase 1 baseline. Ready for the demo!"
echo "=========================================================="
