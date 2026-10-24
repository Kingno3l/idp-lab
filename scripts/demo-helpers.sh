#!/usr/bin/env bash
# Demo Helper Shortcuts for IDP Workshop

demo-baseline() {
  echo "=== [Demo] Checking Baseline State in tenant-core ==="
  kubectl get pods,deployments,configmaps,svc -n tenant-core -o wide
  echo ""
  echo "=== [Demo] Argo CD Application Status ==="
  kubectl get app wave-platform-stack -n argocd
}

demo-cut-git() {
  echo "=== [Demo] Simulating Git Outage / Network Partition ==="
  echo "Scaling deployment/git-server in git-system to 0 replicas..."
  kubectl scale deployment git-server -n git-system --replicas=0
  kubectl wait --for=delete pod -l app=git-server -n git-system --timeout=30s 2>/dev/null || true
  echo "Git server is offline. Argo CD can no longer reach upstream Git."
}

demo-drift() {
  echo "=== [Demo] Introducing Manual Configuration Drift in tenant-core ==="
  echo "1. Modifying ConfigMap platform-runtime-config (LOG_LEVEL=debug)..."
  kubectl patch cm platform-runtime-config -n tenant-core --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'
  echo "2. Scaling edge-gateway deployment to 3 replicas (Git specifies 2)..."
  kubectl scale deployment edge-gateway -n tenant-core --replicas=3
  echo "Drift introduced. Check if Argo CD selfHeal corrects it when Git is accessible."
}

demo-restore-git() {
  echo "=== [Demo] Restoring Git Server ==="
  kubectl scale deployment git-server -n git-system --replicas=1
  echo "Waiting for git-server to become available..."
  kubectl wait --for=condition=available deployment/git-server -n git-system --timeout=60s
  # Ensure HEAD points to main
  kubectl exec deployment/git-server -n git-system -c git-server -- git --git-dir=/git/repo.git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  echo "Git server restored successfully."
}

demo-check-drift() {
  echo "=== [Demo] Checking Argo CD Drift & Sync Status ==="
  kubectl patch app wave-platform-stack -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
  sleep 4
  kubectl get app wave-platform-stack -n argocd
  echo ""
  echo "Current tenant-core workloads:"
  kubectl get pods,deployments,configmaps -n tenant-core
}

# If executed directly instead of sourced, invoke the command passed as argument
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CMD="${1:-}"
  case "$CMD" in
    demo-baseline) demo-baseline ;;
    demo-cut-git) demo-cut-git ;;
    demo-drift) demo-drift ;;
    demo-restore-git) demo-restore-git ;;
    demo-check-drift) demo-check-drift ;;
    *)
      echo "Usage: source scripts/demo-helpers.sh OR ./scripts/demo-helpers.sh <command>"
      echo "Commands:"
      echo "  demo-baseline     - View baseline health and tenant-core resources"
      echo "  demo-cut-git      - Cut Git server connectivity"
      echo "  demo-drift        - Introduce direct Kubernetes state drift"
      echo "  demo-restore-git  - Restore Git server connectivity"
      echo "  demo-check-drift  - Check drift detection and reconciliation status"
      ;;
  esac
fi
