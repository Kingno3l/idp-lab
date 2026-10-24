#!/usr/bin/env bash
set -euo pipefail

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="idp-lab"
LOCAL_GIT_PORT=19418

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   IDP Workshop Environment Automated Setup          ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Step 0: Pre-flight checks
echo -e "\n${YELLOW}[0/7] Pre-flight checks...${NC}"
for tool in docker kind kubectl git nc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}Error: required tool '$tool' is not installed or not in PATH.${NC}"
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo -e "${RED}Error: Docker daemon is not running.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ All prerequisite CLI tools are available.${NC}"

# Clean up any conflicting clusters
echo -e "\n${YELLOW}[1/7] Cleaning up existing kind clusters...${NC}"
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
kind delete cluster --name "basic-idp" 2>/dev/null || true
echo -e "${GREEN}✓ Clean slate confirmed.${NC}"

# Step 1: Create kind cluster
echo -e "\n${YELLOW}[2/7] Creating Kind cluster '${CLUSTER_NAME}'...${NC}"
kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/manifests/kind-config.yaml"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo -e "${GREEN}✓ Cluster created and kubectl configured.${NC}"

# Step 2: Install Argo CD
echo -e "\n${YELLOW}[3/7] Installing Argo CD into namespace 'argocd'...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.10.4/manifests/install.yaml

echo "Configuring Argo CD server for HTTP NodePort (hostPort 8080 -> 30080)..."
# Patch NodePort to 30080 (kind forwards hostPort 8080 -> containerPort 30080)
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 8080, "nodePort": 30080, "name": "http"}]}}'

# Enable unencrypted HTTP on argocd-server so http://localhost:8080 works seamlessly
kubectl patch deployment argocd-server -n argocd -p '{"spec": {"template": {"spec": {"containers": [{"name": "argocd-server", "command": ["argocd-server", "--insecure"]}]}}}}'

echo "Waiting for Argo CD deployments to become ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl wait --for=condition=available deployment/argocd-repo-server -n argocd --timeout=300s

echo -e "${GREEN}✓ Argo CD installed and running in insecure HTTP mode on NodePort 30080.${NC}"

# Step 3: Deploy Git Server
echo -e "\n${YELLOW}[4/7] Deploying in-cluster Git server in namespace 'git-system'...${NC}"
kubectl apply -f "${SCRIPT_DIR}/manifests/git-server.yaml"
kubectl wait --for=condition=available deployment/git-server -n git-system --timeout=300s
echo -e "${GREEN}✓ Git server deployment is 1/1 Ready.${NC}"

# Step 4: Seed Git Repository via port-forward
echo -e "\n${YELLOW}[5/7] Seeding Git repository with application manifests via port-forward...${NC}"
# Ensure bare repo exists in container
kubectl exec deployment/git-server -n git-system -- sh -c '
  mkdir -p /git/repo.git
  if [ ! -f /git/repo.git/HEAD ]; then
    git init --bare /git/repo.git
  fi
  git --git-dir=/git/repo.git config receive.denyCurrentBranch ignore
  git --git-dir=/git/repo.git symbolic-ref HEAD refs/heads/main
'

# Start port-forward in background
kubectl port-forward -n git-system svc/git-server "${LOCAL_GIT_PORT}:9418" >/dev/null 2>&1 &
PF_PID=$!
trap "kill -9 $PF_PID 2>/dev/null || true" EXIT

# Wait for port-forward to be open
for i in {1..30}; do
  if nc -z 127.0.0.1 "${LOCAL_GIT_PORT}" 2>/dev/null; then
    break
  fi
  sleep 1
done

# Prepare seed commit in a temporary directory
TMP_SEED=$(mktemp -d)
(
  cd "$TMP_SEED"
  git init -b main
  mkdir -p apps
  cp "${SCRIPT_DIR}/manifests/apps/"*.yaml apps/
  git config user.email "workshop@idp-lab.local"
  git config user.name "IDP Workshop Seeder"
  git add apps
  git commit -m "feat: initial tenant-core application manifests (sync-waves -1, 0, 1)"
  git remote add origin "git://127.0.0.1:${LOCAL_GIT_PORT}/repo.git"
  git push -u origin main --force
)
rm -rf "$TMP_SEED"
kill -9 "$PF_PID" 2>/dev/null || true
trap - EXIT

# Verify bare repo symbolic-ref points to refs/heads/main
kubectl exec deployment/git-server -n git-system -- git --git-dir=/git/repo.git symbolic-ref HEAD refs/heads/main
echo -e "${GREEN}✓ Git repository seeded successfully with main branch.${NC}"

# Step 5: Register Argo CD Application
echo -e "\n${YELLOW}[6/7] Registering Argo CD Application 'wave-platform-stack'...${NC}"
kubectl create namespace tenant-core --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/manifests/argocd-app.yaml"

# Trigger sync with CreateNamespace=true
kubectl patch app wave-platform-stack -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}},"operation":{"sync":{"prune":true,"syncOptions":["CreateNamespace=true"]}}}'

# Step 6: Wait for Sync and Health Verification
echo -e "\n${YELLOW}[7/7] Verifying sync waves and health status in 'tenant-core'...${NC}"
echo "Waiting for 'platform-runtime-config' ConfigMap (Wave -1)..."
for i in {1..30}; do
  if kubectl get cm platform-runtime-config -n tenant-core >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Waiting for 'redis-store' deployment (Wave 0) to be available..."
kubectl wait --for=condition=available deployment/redis-store -n tenant-core --timeout=300s

echo "Waiting for 'edge-gateway' deployment (Wave 1) to be available..."
kubectl wait --for=condition=available deployment/edge-gateway -n tenant-core --timeout=300s

echo "Waiting for Argo CD application to reach Synced and Healthy status..."
for i in {1..30}; do
  SYNC_STATUS=$(kubectl get app wave-platform-stack -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  HEALTH_STATUS=$(kubectl get app wave-platform-stack -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  if [ "$SYNC_STATUS" == "Synced" ] && [ "$HEALTH_STATUS" == "Healthy" ]; then
    echo -e "${GREEN}✓ Application is ${SYNC_STATUS} and ${HEALTH_STATUS}!${NC}"
    break
  fi
  echo "Current status: Sync=${SYNC_STATUS}, Health=${HEALTH_STATUS}. Waiting..."
  sleep 3
done

# Retrieve admin password
ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(retrieval pending)")

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}   IDP Workshop Environment is READY!                 ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Argo CD UI URL : ${BLUE}http://localhost:8080${NC}"
echo -e "Username       : ${BLUE}admin${NC}"
echo -e "Password       : ${BLUE}${ADMIN_PASS}${NC}"
echo -e "\nWorkloads in tenant-core:"
kubectl get pods,configmaps,svc -n tenant-core
echo -e "\nTo use presenter demo shortcuts:"
echo -e "  source scripts/demo-helpers.sh"
echo -e "  demo-baseline"
