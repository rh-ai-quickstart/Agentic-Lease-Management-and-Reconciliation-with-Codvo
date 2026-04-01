# NeIO LeasingOps - Installation Guide

This guide provides detailed instructions for installing NeIO LeasingOps on Red Hat OpenShift.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Pre-Installation Checklist](#pre-installation-checklist)
- [Installation Methods](#installation-methods)
- [Step-by-Step Installation](#step-by-step-installation)
- [Post-Installation Verification](#post-installation-verification)
- [Upgrade Procedures](#upgrade-procedures)
- [Rollback Procedures](#rollback-procedures)

---

## Prerequisites

### Cluster Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OpenShift Version | 4.14 | 4.15+ |
| Kubernetes Version | 1.27 | 1.28+ |
| Worker Nodes | 3 | 5+ |
| Total CPU (workers) | 24 cores | 48 cores |
| Total Memory (workers) | 64 GB | 128 GB |
| Storage Class | ReadWriteOnce | ReadWriteOnce + ReadWriteMany |

### Required Tools

| Tool | Version | Purpose |
|------|---------|---------|
| `oc` (OpenShift CLI) | 4.14+ | Cluster management |
| `helm` | 3.12+ | Chart installation |
| `kubectl` | 1.27+ | Kubernetes operations |
| `jq` | 1.6+ | JSON processing (scripts) |

**Install OpenShift CLI:**

```bash
# macOS
brew install openshift-cli

# Linux (RHEL/Fedora)
sudo dnf install openshift-clients

# Or download from Red Hat
# https://console.redhat.com/openshift/downloads
```

**Install Helm:**

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### NeIO License Token

A valid NeIO license token is required. Contact sales@codvo.ai to obtain one.

The license token is used to:
- Pull container images from the NeIO registry
- Validate your subscription
- Enable/disable features based on license tier

**Validate your token:**

```bash
export NEIO_LICENSE_TOKEN="your-token-here"

# Run validation script
./scripts/validate-token.sh

# Expected output:
# Token validation successful
# License Type: Enterprise
# Expires: 2025-12-31
# Features: all
```

### Network Requirements

| Protocol | Port | Source | Destination | Purpose |
|----------|------|--------|-------------|---------|
| HTTPS | 443 | Cluster | rhleasingopsacr.azurecr.io | Image pull |
| HTTPS | 443 | Cluster | api.anthropic.com | LLM API |
| HTTPS | 443 | Cluster | api.openai.com | LLM API (optional) |
| HTTPS | 443 | Cluster | api.voyageai.com | Embeddings |
| HTTPS | 443 | Users | OpenShift Route | Application access |

### Storage Requirements

| Component | Storage Class | Size | Access Mode |
|-----------|---------------|------|-------------|
| PostgreSQL | gp3/standard | 50Gi | ReadWriteOnce |
| Redis | gp3/standard | 10Gi | ReadWriteOnce |
| Qdrant | gp3/standard | 100Gi | ReadWriteOnce |
| Object Storage (MinIO) | gp3/standard | 200Gi | ReadWriteOnce |

---

## Pre-Installation Checklist

Complete these checks before installation:

### 1. Cluster Access

```bash
# Verify cluster access
oc whoami
oc version

# Verify admin permissions
oc auth can-i create namespace
oc auth can-i create clusterrole
```

### 2. Storage Class Availability

```bash
# List available storage classes
oc get storageclass

# Verify default storage class
oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'
```

### 3. Resource Availability

```bash
# Check node resources
oc describe nodes | grep -A 5 "Allocatable:"

# Check current usage
oc adm top nodes
```

### 4. Network Connectivity

```bash
# Test registry access (from a debug pod)
oc run network-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}" https://rhleasingopsacr.azurecr.io/v2/

# Test LLM API access
oc run network-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com/
```

---

## Installation Methods

### Method 1: Local Chart (Recommended)

Clone this repository and install from the local Helm chart.

```bash
git clone https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo.git
cd Agentic-Lease-Management-and-Reconciliation-with-Codvo
```

### Method 2: GitOps (ArgoCD)

Deploy via ArgoCD using the chart at `./leasingops/helm` in this repository.

---

## Step-by-Step Installation

### Step 1: Create Namespace

```bash
# Create the namespace
oc new-project leasingops

# Or create with labels
oc create namespace leasingops
oc label namespace leasingops \
  app.kubernetes.io/part-of=neio-leasingops \
  environment=production
```

### Step 2: Generate Pull Secret

The pull secret allows OpenShift to pull images from the NeIO container registry at `rhleasingopsacr.azurecr.io`. Contact bala@codvo.ai or indranil@codvo.ai to request registry credentials.

```bash
# Create the pull secret
oc create secret docker-registry acr-secret \
  --docker-server=rhleasingopsacr.azurecr.io \
  --docker-username=<acr-username> \
  --docker-password=<acr-password> \
  -n leasingops

# Verify
oc get secret acr-secret -n leasingops
```

### Step 3: Configure Secrets

Create secrets for API keys and credentials.

```bash
# Create AI provider secrets
oc create secret generic ai-credentials \
  --from-literal=ANTHROPIC_API_KEY='sk-ant-...' \
  --from-literal=VOYAGE_API_KEY='pa-...' \
  -n leasingops

# Create database credentials (if using external database)
oc create secret generic db-credentials \
  --from-literal=POSTGRES_PASSWORD='strong-password' \
  -n leasingops

# Verify secrets
oc get secrets -n leasingops
```

### Step 4: Prepare Values File

Create a custom values file for your environment.

```bash
# Copy the OpenShift values file
cp leasingops/helm/values-openshift.yaml my-values.yaml
```

**Edit `my-values.yaml`:**

```yaml
global:
  # Required: Your NeIO license token
  licenseToken: "your-license-token"

  # Required: Your application domain
  domain: "leasingops.apps.your-cluster.example.com"

  # Storage class for persistent volumes
  storageClass: "gp3"

  # Image pull secrets
  imagePullSecrets:
    - acr-secret

# Application configuration
app:
  replicas: 2
  env:
    apiUrl: "https://leasingops.apps.your-cluster.example.com/api"

# API configuration
api:
  replicas: 3
  secrets:
    - ai-credentials

# Worker configuration
worker:
  replicas: 2
  concurrency: 4

# Database configuration
postgresql:
  enabled: true
  auth:
    existingSecret: "db-credentials"
    secretKeys:
      adminPasswordKey: "POSTGRES_PASSWORD"

# AI provider configuration
ai:
  provider: "anthropic"
  model: "claude-sonnet-4-20250514"
  embeddingModel: "voyage-3"
```

### Step 5: Install the Chart

```bash
helm install leasingops ./leasingops/helm \
  --namespace leasingops \
  -f my-values.yaml \
  --wait \
  --timeout 10m
```

**Expected output:**

```
NAME: leasingops
LAST DEPLOYED: Mon Jan 15 10:30:00 2025
NAMESPACE: leasingops
STATUS: deployed
REVISION: 1
NOTES:
NeIO LeasingOps has been installed.

Application URL: https://leasingops.apps.your-cluster.example.com
API URL: https://leasingops.apps.your-cluster.example.com/api

To verify the installation:
  oc get pods -n leasingops
```

### Step 6: Wait for Deployment

```bash
# Wait for all pods to be ready
oc wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=leasingops \
  -n leasingops \
  --timeout=300s

# Check pod status
oc get pods -n leasingops -w
```

---

## Post-Installation Verification

### 1. Check Pod Status

```bash
# All pods should be Running
oc get pods -n leasingops

# Expected output:
# NAME                                  READY   STATUS    RESTARTS   AGE
# leasingops-app-xxx-xxx               1/1     Running   0          5m
# leasingops-app-xxx-yyy               1/1     Running   0          5m
# leasingops-api-xxx-xxx               1/1     Running   0          5m
# leasingops-api-xxx-yyy               1/1     Running   0          5m
# leasingops-api-xxx-zzz               1/1     Running   0          5m
# leasingops-worker-xxx-xxx            1/1     Running   0          5m
# leasingops-worker-xxx-yyy            1/1     Running   0          5m
# leasingops-postgresql-0              1/1     Running   0          5m
# leasingops-redis-master-0            1/1     Running   0          5m
# leasingops-qdrant-0                  1/1     Running   0          5m
```

### 2. Verify Services

```bash
# List services
oc get svc -n leasingops

# Check endpoints
oc get endpoints -n leasingops
```

### 3. Test Health Endpoints

```bash
# Get the route URL
ROUTE_URL=$(oc get route leasingops-app -n leasingops -o jsonpath='{.spec.host}')

# Test application health
curl -s https://$ROUTE_URL/api/health | jq

# Expected response:
# {
#   "status": "healthy",
#   "version": "1.0.0",
#   "components": {
#     "database": "connected",
#     "redis": "connected",
#     "qdrant": "connected",
#     "ai_provider": "available"
#   }
# }
```

### 4. Access the Application

```bash
# Get the application URL
echo "Application URL: https://$(oc get route leasingops-app -n leasingops -o jsonpath='{.spec.host}')"

# Open in browser
open "https://$(oc get route leasingops-app -n leasingops -o jsonpath='{.spec.host}')"
```

### 5. Verify Database Connectivity

```bash
# Connect to PostgreSQL
oc exec -it leasingops-postgresql-0 -n leasingops -- \
  psql -U postgres -d leasingops -c "SELECT version();"

# Check tables
oc exec -it leasingops-postgresql-0 -n leasingops -- \
  psql -U postgres -d leasingops -c "\dt"
```

### 6. Verify Vector Store

```bash
# Check Qdrant collections
curl -s http://leasingops-qdrant:6333/collections | jq

# Or via port-forward
oc port-forward svc/leasingops-qdrant 6333:6333 -n leasingops &
curl -s http://localhost:6333/collections | jq
```

### 7. Test AI Integration

```bash
# Send a test query to the chat endpoint
curl -X POST https://$ROUTE_URL/api/v1/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{"message": "What are the key terms in a dry lease?"}' | jq
```

---

## Upgrade Procedures

### Pre-Upgrade Checklist

1. **Backup database**
   ```bash
   oc exec leasingops-postgresql-0 -n leasingops -- \
     pg_dump -U postgres leasingops > backup-$(date +%Y%m%d).sql
   ```

2. **Review release notes**
   ```bash
   # Pull latest chart from git
   git -C Agentic-Lease-Management-and-Reconciliation-with-Codvo pull
   ```

3. **Compare values**
   ```bash
   helm get values leasingops -n leasingops > current-values.yaml
   helm show values ./leasingops/helm > new-default-values.yaml
   diff current-values.yaml new-default-values.yaml
   ```

### Upgrade Steps

```bash
# Dry-run upgrade to preview changes
helm upgrade leasingops ./leasingops/helm \
  --namespace leasingops \
  -f my-values.yaml \
  --dry-run

# Perform the upgrade
helm upgrade leasingops ./leasingops/helm \
  --namespace leasingops \
  -f my-values.yaml \
  --wait \
  --timeout 10m

# Verify upgrade
helm history leasingops -n leasingops
oc get pods -n leasingops
```

### Database Migrations

If the upgrade includes database schema changes:

```bash
# Run migrations
oc exec -it deployment/leasingops-api -n leasingops -- \
  python -m alembic upgrade head

# Verify migration status
oc exec -it deployment/leasingops-api -n leasingops -- \
  python -m alembic current
```

---

## Rollback Procedures

### Helm Rollback

```bash
# View release history
helm history leasingops -n leasingops

# Rollback to previous revision
helm rollback leasingops 1 -n leasingops

# Rollback to specific revision
helm rollback leasingops 3 -n leasingops

# Verify rollback
oc get pods -n leasingops
helm status leasingops -n leasingops
```

### Database Rollback

```bash
# Downgrade migrations
oc exec -it deployment/leasingops-api -n leasingops -- \
  python -m alembic downgrade -1

# Restore from backup (if needed)
oc exec -i leasingops-postgresql-0 -n leasingops -- \
  psql -U postgres -d leasingops < backup-20250115.sql
```

---

## Uninstallation

### Complete Removal

```bash
# Uninstall Helm release
helm uninstall leasingops -n leasingops

# Delete PVCs (data will be lost!)
oc delete pvc --all -n leasingops

# Delete secrets
oc delete secret --all -n leasingops

# Delete namespace
oc delete namespace leasingops
```

### Partial Removal (Keep Data)

```bash
# Uninstall without deleting PVCs
helm uninstall leasingops -n leasingops

# PVCs remain:
oc get pvc -n leasingops
```

---

## Next Steps

- [Configuration Reference](./CONFIGURATION.md) - Customize your deployment
- [Troubleshooting](./TROUBLESHOOTING.md) - Common issues and solutions
- [Security Guide](./SECURITY.md) - Security best practices
- [Air-Gapped Deployment](./AIRGAPPED.md) - Offline installation
