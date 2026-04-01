# NeIO LeasingOps - Air-Gapped Deployment Guide

This guide covers deploying NeIO LeasingOps in air-gapped (disconnected) environments where there is no internet access.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Image Mirroring Process](#image-mirroring-process)
- [Offline Model Deployment](#offline-model-deployment)
- [Network Policies](#network-policies)
- [Certificate Management](#certificate-management)
- [Deployment Steps](#deployment-steps)
- [Maintenance and Updates](#maintenance-and-updates)

---

## Overview

An air-gapped deployment requires:

1. **Container Images** - Mirrored to an internal registry
2. **AI Models** - Downloaded and served locally via OpenShift AI
3. **Helm Charts** - Available locally or in an internal chart repository
4. **Certificates** - Internal CA for TLS

```mermaid
graph TB
    subgraph "Connected Environment"
        NEIO_REG[rhleasingopsacr.azurecr.io]
        HELM_REPO[GitHub QuickStart Repo]
        MODEL_HUB[HuggingFace Hub]
    end

    subgraph "Transfer Medium"
        PORTABLE[(Portable Storage<br/>USB/DVD)]
    end

    subgraph "Air-Gapped Environment"
        INT_REG[Internal Registry]
        INT_CHARTS[Internal Chart Repo]
        INT_MODELS[Model Storage]
        OCP[OpenShift Cluster]
    end

    NEIO_REG -->|Mirror Images| PORTABLE
    HELM_REPO -->|Download Charts| PORTABLE
    MODEL_HUB -->|Download Models| PORTABLE

    PORTABLE -->|Import| INT_REG
    PORTABLE -->|Import| INT_CHARTS
    PORTABLE -->|Import| INT_MODELS

    INT_REG --> OCP
    INT_CHARTS --> OCP
    INT_MODELS --> OCP
```

---

## Prerequisites

### Connected Workstation Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| `oc` | 4.14+ | Mirror registry management |
| `skopeo` | 1.9+ | Image copying |
| `helm` | 3.12+ | Chart packaging |
| `oc-mirror` | 4.14+ | OpenShift mirror plugin |
| Internet access | - | Download from external registries |

### Air-Gapped Environment Requirements

| Component | Requirement |
|-----------|-------------|
| Internal Container Registry | Harbor, Quay, or OpenShift internal registry |
| Storage | 100GB+ for images, 50GB+ per LLM model |
| OpenShift | 4.14+ with disconnected installation |
| OpenShift AI | 2.x for local model serving |

---

## Image Mirroring Process

### Step 1: Create Image List

Create a file listing all required images:

```bash
# images.txt
rhleasingopsacr.azurecr.io/leasingops-app:1.0.0
rhleasingopsacr.azurecr.io/leasingops-api:1.0.0
rhleasingopsacr.azurecr.io/leasingops-worker:1.0.0
docker.io/bitnami/postgresql:16
docker.io/bitnami/redis:7.2
docker.io/qdrant/qdrant:v1.7.4
docker.io/minio/minio:latest
quay.io/modh/vllm:latest
```

### Step 2: Mirror Images (Connected Environment)

**Using skopeo:**

```bash
#!/bin/bash
# mirror-images.sh

SOURCE_REGISTRY="rhleasingopsacr.azurecr.io"
TARGET_REGISTRY="internal-registry.example.com"
NEIO_TOKEN="${NEIO_LICENSE_TOKEN}"

# Login to source registry
skopeo login ${SOURCE_REGISTRY} -u license -p ${NEIO_TOKEN}

# Mirror each image
while read image; do
    src_image="${image}"
    # Replace source registry with target
    dst_image=$(echo ${image} | sed "s|rhleasingopsacr.azurecr.io|${TARGET_REGISTRY}|g")
    dst_image=$(echo ${dst_image} | sed "s|docker.io|${TARGET_REGISTRY}|g")
    dst_image=$(echo ${dst_image} | sed "s|quay.io|${TARGET_REGISTRY}|g")

    echo "Mirroring ${src_image} -> ${dst_image}"
    skopeo copy \
        --all \
        docker://${src_image} \
        docker://${dst_image}
done < images.txt
```

**Using oc-mirror (Recommended for OpenShift):**

```yaml
# imageset-config.yaml
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
storageConfig:
  local:
    path: ./mirror-data
mirror:
  additionalImages:
    - name: rhleasingopsacr.azurecr.io/leasingops-app:1.0.0
    - name: rhleasingopsacr.azurecr.io/leasingops-api:1.0.0
    - name: rhleasingopsacr.azurecr.io/leasingops-worker:1.0.0
    - name: docker.io/bitnami/postgresql:16
    - name: docker.io/bitnami/redis:7.2
    - name: docker.io/qdrant/qdrant:v1.7.4
```

```bash
# Create mirror archive
oc mirror --config imageset-config.yaml file://mirror-output

# Transfer mirror-output directory to air-gapped environment

# In air-gapped environment, push to internal registry
oc mirror --from file://mirror-output docker://internal-registry.example.com
```

### Step 3: Export to Portable Media

```bash
# Create tarball for transfer
tar -cvzf leasingops-images-v1.0.0.tar.gz mirror-output/

# Write to portable media
# Verify checksum
sha256sum leasingops-images-v1.0.0.tar.gz > checksum.sha256
```

### Step 4: Import in Air-Gapped Environment

```bash
# Verify checksum
sha256sum -c checksum.sha256

# Extract
tar -xvzf leasingops-images-v1.0.0.tar.gz

# Push to internal registry
oc mirror --from file://mirror-output docker://internal-registry.example.com

# Verify images
skopeo list-tags docker://internal-registry.example.com/leasingops/api
```

---

## Offline Model Deployment

### Supported Models

| Model | Size | Purpose | License |
|-------|------|---------|---------|
| Mistral-7B-Instruct | 14GB | Primary LLM | Apache 2.0 |
| Llama-2-13B-Chat | 26GB | Alternative LLM | Llama 2 License |
| BGE-Large-EN | 1.3GB | Embeddings | MIT |
| all-MiniLM-L6-v2 | 80MB | Embeddings (small) | Apache 2.0 |

### Step 1: Download Models (Connected Environment)

```bash
# Install huggingface-cli
pip install huggingface-hub

# Download Mistral-7B-Instruct
huggingface-cli download mistralai/Mistral-7B-Instruct-v0.2 \
    --local-dir ./models/mistral-7b-instruct \
    --local-dir-use-symlinks False

# Download BGE embeddings
huggingface-cli download BAAI/bge-large-en-v1.5 \
    --local-dir ./models/bge-large-en \
    --local-dir-use-symlinks False

# Create archive
tar -cvzf models-v1.0.0.tar.gz models/
sha256sum models-v1.0.0.tar.gz > models-checksum.sha256
```

### Step 2: Transfer and Deploy Models

```bash
# In air-gapped environment
tar -xvzf models-v1.0.0.tar.gz

# Create PVC for model storage
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage
  namespace: leasingops
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-cephfs
EOF

# Copy models to PVC (via temporary pod)
oc run model-copy --image=busybox --rm -it --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "model-copy",
      "image": "busybox",
      "volumeMounts": [{
        "name": "models",
        "mountPath": "/models"
      }]
    }],
    "volumes": [{
      "name": "models",
      "persistentVolumeClaim": {
        "claimName": "model-storage"
      }
    }]
  }
}' \
  -n leasingops -- sh -c "echo 'Ready for model copy'"

# Use oc rsync to copy models
oc rsync ./models/ model-copy:/models/ -n leasingops
```

### Step 3: Configure OpenShift AI for Local Serving

```yaml
# inference-service.yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-7b
  namespace: leasingops
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      runtime: vllm
      storageUri: pvc://model-storage/mistral-7b-instruct
      resources:
        limits:
          nvidia.com/gpu: 1
          cpu: 8
          memory: 32Gi
        requests:
          nvidia.com/gpu: 1
          cpu: 4
          memory: 16Gi
      env:
        - name: MODEL_ID
          value: /mnt/models
        - name: MAX_MODEL_LEN
          value: "8192"
        - name: TENSOR_PARALLEL_SIZE
          value: "1"
```

```bash
# Deploy InferenceService
oc apply -f inference-service.yaml

# Wait for ready
oc wait --for=condition=Ready inferenceservice/mistral-7b -n leasingops --timeout=600s
```

### Step 4: Configure Local Embeddings

```yaml
# embedding-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embedding-service
  namespace: leasingops
spec:
  replicas: 2
  selector:
    matchLabels:
      app: embedding-service
  template:
    metadata:
      labels:
        app: embedding-service
    spec:
      containers:
        - name: embeddings
          image: internal-registry.example.com/leasingops/embeddings:1.0.0
          ports:
            - containerPort: 8080
          env:
            - name: MODEL_PATH
              value: /models/bge-large-en
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
          resources:
            requests:
              cpu: 2
              memory: 4Gi
            limits:
              cpu: 4
              memory: 8Gi
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-storage
```

---

## Network Policies

### Default Deny Policy

```yaml
# network-policy-default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: leasingops
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Application Network Policies

```yaml
# network-policy-app.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-traffic
  namespace: leasingops
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: app
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from OpenShift Router
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - port: 3000
          protocol: TCP
  egress:
    # Allow to API
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: api
      ports:
        - port: 8000
          protocol: TCP
    # Allow DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              dns: coredns
      ports:
        - port: 53
          protocol: UDP
```

```yaml
# network-policy-api.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-traffic
  namespace: leasingops
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from App
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: app
      ports:
        - port: 8000
          protocol: TCP
    # Allow from Worker
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: worker
      ports:
        - port: 8000
          protocol: TCP
  egress:
    # Allow to PostgreSQL
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql
      ports:
        - port: 5432
          protocol: TCP
    # Allow to Redis
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: redis
      ports:
        - port: 6379
          protocol: TCP
    # Allow to Qdrant
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: qdrant
      ports:
        - port: 6333
          protocol: TCP
    # Allow to local LLM
    - to:
        - podSelector:
            matchLabels:
              serving.kserve.io/inferenceservice: mistral-7b
      ports:
        - port: 8080
          protocol: TCP
    # Allow DNS
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
```

### Apply Network Policies

```bash
# Apply all network policies
oc apply -f network-policy-default-deny.yaml
oc apply -f network-policy-app.yaml
oc apply -f network-policy-api.yaml

# Verify policies
oc get networkpolicy -n leasingops
```

---

## Certificate Management

### Internal CA Setup

```bash
# Generate CA key and certificate
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt -subj "/CN=LeasingOps Internal CA"

# Create ConfigMap for CA
oc create configmap internal-ca \
    --from-file=ca-bundle.crt=ca.crt \
    -n leasingops
```

### Generate Application Certificates

```bash
# Generate server key
openssl genrsa -out server.key 2048

# Generate CSR
openssl req -new -key server.key -out server.csr \
    -subj "/CN=leasingops.apps.cluster.local"

# Create certificate configuration
cat > server.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = leasingops.apps.cluster.local
DNS.2 = leasingops-api.leasingops.svc
DNS.3 = leasingops-app.leasingops.svc
DNS.4 = *.leasingops.svc.cluster.local
EOF

# Sign certificate
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -days 365 -sha256 -extfile server.ext

# Create TLS secret
oc create secret tls leasingops-tls \
    --cert=server.crt \
    --key=server.key \
    -n leasingops
```

### Configure Route with TLS

```yaml
# route-tls.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: leasingops-app
  namespace: leasingops
spec:
  host: leasingops.apps.cluster.local
  to:
    kind: Service
    name: leasingops-app
  port:
    targetPort: http
  tls:
    termination: edge
    certificate: |
      -----BEGIN CERTIFICATE-----
      # Your server certificate
      -----END CERTIFICATE-----
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      # Your server key
      -----END RSA PRIVATE KEY-----
    caCertificate: |
      -----BEGIN CERTIFICATE-----
      # Your CA certificate
      -----END CERTIFICATE-----
    insecureEdgeTerminationPolicy: Redirect
```

### Trust Internal CA in Pods

```yaml
# Add to deployment spec
spec:
  containers:
    - name: api
      volumeMounts:
        - name: ca-bundle
          mountPath: /etc/pki/ca-trust/source/anchors/
          readOnly: true
      env:
        - name: REQUESTS_CA_BUNDLE
          value: /etc/pki/ca-trust/source/anchors/ca-bundle.crt
  volumes:
    - name: ca-bundle
      configMap:
        name: internal-ca
```

---

## Deployment Steps

### Step 1: Prepare Air-Gapped Values

```yaml
# values-airgapped.yaml
global:
  licenseToken: "<your-license-token>"
  domain: "leasingops.apps.cluster.local"

  # Internal registry
  imageRegistry: "internal-registry.example.com"
  imagePullSecrets:
    - internal-registry-secret

# Override all images
app:
  image:
    repository: internal-registry.example.com/leasingops/app
    tag: "1.0.0"

api:
  image:
    repository: internal-registry.example.com/leasingops/api
    tag: "1.0.0"

worker:
  image:
    repository: internal-registry.example.com/leasingops/worker
    tag: "1.0.0"

postgresql:
  image:
    registry: internal-registry.example.com
    repository: bitnami/postgresql
    tag: "16"

redis:
  image:
    registry: internal-registry.example.com
    repository: bitnami/redis
    tag: "7.2"

qdrant:
  image:
    repository: internal-registry.example.com/qdrant/qdrant
    tag: "v1.7.4"

# AI Configuration for local serving
ai:
  provider: "openshift-ai"

  openshiftAI:
    enabled: true
    servingRuntime: "vllm"
    modelName: "mistral-7b"
    endpoint: "http://mistral-7b.leasingops.svc.cluster.local"

  embedding:
    provider: "local"
    local:
      enabled: true
      endpoint: "http://embedding-service.leasingops.svc.cluster.local:8080"

# Disable external dependencies
externalDependencies:
  allowExternalAI: false
  allowTelemetry: false
  allowExternalStorage: false
```

### Step 2: Package and Transfer Helm Chart

```bash
# In connected environment — clone repo and package chart
git clone https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo.git
helm package Agentic-Lease-Management-and-Reconciliation-with-Codvo/leasingops/helm

# Transfer leasingops-*.tgz to air-gapped environment

# In air-gapped environment, install from local chart
helm install leasingops ./leasingops-*.tgz \
    --namespace leasingops \
    -f values-airgapped.yaml
```

### Step 3: Verify Deployment

```bash
# Check all pods
oc get pods -n leasingops

# Verify no external network attempts
oc logs deployment/leasingops-api -n leasingops | grep -i "connection refused\|timeout"

# Test local LLM
curl http://mistral-7b.leasingops.svc.cluster.local/v1/models

# Test health
curl https://leasingops.apps.cluster.local/api/health
```

---

## Maintenance and Updates

### Updating Images

1. Download new images in connected environment
2. Mirror to portable media
3. Import to internal registry
4. Update Helm values with new tags
5. Perform rolling upgrade

```bash
# Update deployment
helm upgrade leasingops ./leasingops-1.1.0.tgz \
    --namespace leasingops \
    -f values-airgapped.yaml \
    --set app.image.tag=1.1.0 \
    --set api.image.tag=1.1.0
```

### Updating Models

1. Download new model in connected environment
2. Create versioned archive
3. Transfer to air-gapped environment
4. Upload to model storage PVC
5. Update InferenceService to point to new model

```bash
# Update model path
oc patch inferenceservice mistral-7b -n leasingops \
    --type merge \
    -p '{"spec":{"predictor":{"model":{"storageUri":"pvc://model-storage/mistral-7b-v2"}}}}'
```

### Backup Procedures

```bash
# Backup PostgreSQL
oc exec leasingops-postgresql-0 -n leasingops -- \
    pg_dump -U postgres leasingops > backup-$(date +%Y%m%d).sql

# Backup Qdrant collections
curl http://leasingops-qdrant:6333/collections/documents/snapshots \
    -X POST -H "Content-Type: application/json" \
    -d '{"wait": true}'

# Copy snapshots to external storage
oc rsync leasingops-qdrant-0:/qdrant/snapshots/ ./backups/qdrant/
```

---

## Troubleshooting Air-Gapped Issues

### Image Pull Failures

```bash
# Check image exists in internal registry
skopeo inspect docker://internal-registry.example.com/leasingops/api:1.0.0

# Verify pull secret
oc get secret internal-registry-secret -n leasingops -o yaml
```

### Model Loading Failures

```bash
# Check model files on PVC
oc exec -it model-copy -n leasingops -- ls -la /models/mistral-7b-instruct

# Check InferenceService logs
oc logs -l serving.kserve.io/inferenceservice=mistral-7b -n leasingops
```

### Certificate Issues

```bash
# Test certificate chain
openssl s_client -connect leasingops.apps.cluster.local:443 -CAfile ca.crt

# Verify CA is trusted in pod
oc exec deployment/leasingops-api -n leasingops -- \
    cat /etc/pki/ca-trust/source/anchors/ca-bundle.crt
```

---

## Next Steps

- [Security Guide](./SECURITY.md) - Security hardening
- [Troubleshooting](./TROUBLESHOOTING.md) - Common issues
- [Configuration Reference](./CONFIGURATION.md) - Full configuration options
