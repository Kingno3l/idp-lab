# Internal Developer Platform (IDP) Workshop Lab

An automated local Kubernetes and GitOps laboratory simulating an enterprise Internal Developer Platform environment using **Kind**, **Argo CD**, and an in-cluster **Git daemon** server.

---

## Architecture Overview

- **Cluster Runtime**: [Kind (Kubernetes in Docker)](https://kind.sigs.k8s.io/) configured with extra port mappings:
  - `80:80` (HTTP Ingress / Gateway)
  - `443:443` (HTTPS Ingress)
  - `8080:30080` (Argo CD Web UI via NodePort)
- **GitOps Engine**: [Argo CD v2.10](https://argo-cd.readthedocs.io/) running in `argocd` namespace in unencrypted HTTP mode for immediate browser access.
- **In-Cluster Git Server**: An isolated Alpine-based Git daemon running in `git-system` namespace backed by persistent storage, serving `git://git-server.git-system.svc.cluster.local/repo.git`.
- **Tenant Workloads (`tenant-core` namespace)** deployed across **Argo CD Sync Waves**:
  - **Wave -1**: `platform-runtime-config` (ConfigMap containing environment configuration)
  - **Wave 0**: `redis-store` (Redis 7.0 Deployment + ClusterIP Service)
  - **Wave 1**: `edge-gateway` (NGINX 1.25 Deployment with 2 replicas + ClusterIP Service referencing runtime configuration)

---

## Prerequisites

Before starting, ensure you have the following installed on your machine:

1. **Docker**: Docker Desktop (macOS/Windows) or Docker Engine (Linux) running.
2. **Kind**: `v0.20+` ([Installation Guide](https://kind.sigs.k8s.io/docs/user/quick-start/#installation))
3. **kubectl**: `v1.27+` ([Installation Guide](https://kubernetes.io/docs/tasks/tools/))
4. **Git**: Installed and configured.
5. **netcat (`nc`)**: Included by default on macOS and most Linux distros.

---

## Quick Start (Automated Setup)

### 1. Clone the Repository
```bash
git clone https://github.com/Kingno3l/idp-lab.git
cd idp-lab
```

### 2. Run the Setup Script
```bash
chmod +x setup.sh tear-down.sh scripts/*.sh
./setup.sh
```

The script will automatically:
1. Validate required CLI tools and Docker connectivity.
2. Clean up any existing `idp-lab` Kind cluster.
3. Spin up the `idp-lab` Kind cluster with host port bindings (`80`, `443`, `8080`).
4. Install and configure Argo CD with unencrypted HTTP NodePort access.
5. Deploy the in-cluster Git server in namespace `git-system`.
6. Seed the Git repository with the `apps/` manifests via temporary port-forwarding.
7. Register the `wave-platform-stack` Application and trigger initial synchronization across waves.
8. Validate that all tenant workloads reach `1/1` or `2/2` Ready states and the application reports `Synced` and `Healthy`.

---

## Accessing the Argo CD UI

Once setup finishes, open your web browser:

- **URL**: [http://localhost:8080](http://localhost:8080)
- **Username**: `admin`
- **Password**: Retrieve the initial admin password with:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
  ```

---

## Verifying Tenant Workloads

Check that the sync wave deployment completed successfully:

```bash
kubectl get pods,configmaps,svc -n tenant-core -o wide
```

Expected output:
```
NAME                                READY   STATUS    RESTARTS   AGE
pod/edge-gateway-xxx                1/1     Running   0          ...
pod/edge-gateway-yyy                1/1     Running   0          ...
pod/redis-store-zzz                 1/1     Running   0          ...

NAME                                DATA   AGE
configmap/platform-runtime-config   3      ...

NAME                   TYPE        CLUSTER-IP   PORT(S)
service/edge-gateway   ClusterIP   ...          80/TCP
service/redis-store    ClusterIP   ...          6379/TCP
```

Check the Argo CD application status:
```bash
kubectl get app wave-platform-stack -n argocd
```

---

## Presenter / Demo Shortcuts

We provide presenter shortcuts to demonstrate GitOps resilience and configuration drift:

```bash
# Source the helper script to load shortcut functions into your shell:
source scripts/demo-helpers.sh

# 1. View baseline application health:
demo-baseline

# 2. Simulate an upstream Git outage:
demo-cut-git

# 3. Introduce manual configuration drift directly in the cluster:
demo-drift

# 4. Restore Git connectivity:
demo-restore-git

# 5. Check automated self-healing and reconciliation:
demo-check-drift
```

Alternatively, run individual commands directly:
```bash
./scripts/demo-helpers.sh demo-baseline
```

---

## Teardown

To completely destroy the cluster and release all allocated ports:

```bash
./tear-down.sh
```
