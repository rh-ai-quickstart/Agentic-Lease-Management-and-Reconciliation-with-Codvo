# NeIO LeasingOps - Configuration Reference

This document provides a complete reference for all configuration options available in NeIO LeasingOps.

## Table of Contents

- [Helm Values Reference](#helm-values-reference)
- [Environment Variables](#environment-variables)
- [Secret Management](#secret-management)
- [Feature Flags](#feature-flags)
- [AI Provider Configuration](#ai-provider-configuration)
- [Example Configurations](#example-configurations)

---

## Helm Values Reference

### Global Configuration

```yaml
global:
  # Required: NeIO license token
  licenseToken: ""

  # Required: Application domain (without protocol)
  domain: ""

  # Storage class for persistent volumes
  storageClass: "gp3"

  # Image pull secrets for NeIO registry
  imagePullSecrets:
    - acr-secret

  # Image registry override
  imageRegistry: "rhleasingopsacr.azurecr.io"

  # Common labels applied to all resources
  labels: {}

  # Common annotations applied to all resources
  annotations: {}

  # Node selector applied to all pods
  nodeSelector: {}

  # Tolerations applied to all pods
  tolerations: []
```

### Namespace Configuration

```yaml
namespace:
  # Create namespace (set false if using existing)
  create: true

  # Namespace name
  name: "leasingops"

  # Namespace labels
  labels:
    environment: production
    app.kubernetes.io/part-of: neio-leasingops
```

### Application (Frontend) Configuration

```yaml
app:
  # Enable/disable app deployment
  enabled: true

  # Number of replicas
  replicaCount: 2

  # Image configuration
  image:
    repository: rhleasingopsacr.azurecr.io/leasingops-app
    tag: ""  # Defaults to Chart.appVersion
    pullPolicy: IfNotPresent

  # Pod annotations
  podAnnotations: {}

  # Pod labels
  podLabels: {}

  # Pod security context
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

  # Container security context
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop:
        - ALL

  # Resource requests and limits
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 1Gi

  # Horizontal Pod Autoscaler
  autoscaling:
    enabled: false
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 80
    targetMemoryUtilizationPercentage: 80

  # Environment variables
  env:
    nodeEnv: "production"
    apiUrl: ""  # Auto-configured from global.domain
    extraEnv: {}

  # ConfigMaps to mount as environment
  envFrom: []

  # Liveness probe configuration
  livenessProbe:
    path: /api/health
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3

  # Readiness probe configuration
  readinessProbe:
    path: /api/health
    initialDelaySeconds: 10
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 3

  # Service configuration
  service:
    type: ClusterIP
    port: 80
    targetPort: 3000

  # Ingress/Route configuration
  route:
    enabled: true
    host: ""  # Auto-configured from global.domain
    tls:
      termination: edge
      insecureEdgeTerminationPolicy: Redirect
    annotations: {}

  # Node selector
  nodeSelector: {}

  # Tolerations
  tolerations: []

  # Affinity rules
  affinity: {}

  # Pod disruption budget
  pdb:
    enabled: true
    minAvailable: 1
```

### API Configuration

```yaml
api:
  # Enable/disable API deployment
  enabled: true

  # Number of replicas
  replicaCount: 3

  # Image configuration
  image:
    repository: rhleasingopsacr.azurecr.io/leasingops-api
    tag: ""
    pullPolicy: IfNotPresent

  # Resource requests and limits
  resources:
    requests:
      cpu: 2
      memory: 4Gi
    limits:
      cpu: 4
      memory: 8Gi

  # Horizontal Pod Autoscaler
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70
    behavior:
      scaleDown:
        stabilizationWindowSeconds: 300

  # Environment variables
  env:
    pythonEnv: "production"
    logLevel: "INFO"
    workersPerCore: 2
    maxWorkers: 8
    extraEnv: {}

  # Secrets to mount as environment
  secrets:
    - ai-credentials
    - db-credentials

  # Liveness probe
  livenessProbe:
    path: /health
    initialDelaySeconds: 30
    periodSeconds: 10

  # Readiness probe
  readinessProbe:
    path: /health/ready
    initialDelaySeconds: 10
    periodSeconds: 5

  # Service configuration
  service:
    type: ClusterIP
    port: 8000

  # Pod disruption budget
  pdb:
    enabled: true
    minAvailable: 2

  # Node selector
  nodeSelector: {}

  # Tolerations
  tolerations: []

  # Affinity (prefer spreading across zones)
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/component: api
            topologyKey: topology.kubernetes.io/zone
```

### Worker Configuration

```yaml
worker:
  # Enable/disable worker deployment
  enabled: true

  # Number of replicas
  replicaCount: 2

  # Image configuration
  image:
    repository: rhleasingopsacr.azurecr.io/leasingops-worker
    tag: ""
    pullPolicy: IfNotPresent

  # Worker concurrency (tasks per worker)
  concurrency: 4

  # Queue names to process
  queues:
    - default
    - documents
    - ai_pipeline
    - notifications

  # Resource requests and limits
  resources:
    requests:
      cpu: 2
      memory: 4Gi
    limits:
      cpu: 4
      memory: 8Gi

  # Horizontal Pod Autoscaler
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    # Scale based on queue depth
    metrics:
      - type: External
        external:
          metric:
            name: redis_queue_depth
          target:
            type: AverageValue
            averageValue: 100

  # Environment variables
  env:
    logLevel: "INFO"
    extraEnv: {}

  # Liveness probe
  livenessProbe:
    exec:
      command:
        - /bin/sh
        - -c
        - celery -A app.worker inspect ping
    initialDelaySeconds: 60
    periodSeconds: 30

  # Pod disruption budget
  pdb:
    enabled: true
    minAvailable: 1
```

### PostgreSQL Configuration

```yaml
postgresql:
  # Enable internal PostgreSQL (set false for external)
  enabled: true

  # Architecture: standalone or replication
  architecture: standalone

  # Authentication
  auth:
    # Use existing secret for password
    existingSecret: ""
    secretKeys:
      adminPasswordKey: "postgres-password"
    # Or specify directly (not recommended for production)
    postgresPassword: ""
    database: leasingops

  # Primary configuration
  primary:
    # Resource configuration
    resources:
      requests:
        cpu: 1
        memory: 2Gi
      limits:
        cpu: 2
        memory: 4Gi

    # Persistence
    persistence:
      enabled: true
      size: 50Gi
      storageClass: ""  # Uses global.storageClass

    # PostgreSQL configuration
    configuration: |
      max_connections = 200
      shared_buffers = 512MB
      effective_cache_size = 1536MB
      maintenance_work_mem = 128MB
      checkpoint_completion_target = 0.9
      wal_buffers = 16MB
      default_statistics_target = 100
      random_page_cost = 1.1
      effective_io_concurrency = 200

    # pgvector extension
    initdb:
      scripts:
        init-pgvector.sql: |
          CREATE EXTENSION IF NOT EXISTS vector;

  # Read replicas (when architecture=replication)
  readReplicas:
    replicaCount: 1
    resources:
      requests:
        cpu: 500m
        memory: 1Gi

# External PostgreSQL (when postgresql.enabled=false)
externalPostgresql:
  host: ""
  port: 5432
  database: leasingops
  username: leasingops
  existingSecret: ""
  existingSecretPasswordKey: "password"
```

### Redis Configuration

```yaml
redis:
  # Enable internal Redis
  enabled: true

  # Architecture: standalone or replication
  architecture: standalone

  # Authentication
  auth:
    enabled: true
    existingSecret: ""
    existingSecretPasswordKey: "redis-password"

  # Master configuration
  master:
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1
        memory: 2Gi

    persistence:
      enabled: true
      size: 10Gi

# External Redis (when redis.enabled=false)
externalRedis:
  host: ""
  port: 6379
  password: ""
  existingSecret: ""
```

### Qdrant Configuration

```yaml
qdrant:
  # Enable internal Qdrant
  enabled: true

  # Replicas for HA
  replicaCount: 1

  # Resource configuration
  resources:
    requests:
      cpu: 2
      memory: 4Gi
    limits:
      cpu: 4
      memory: 8Gi

  # Persistence
  persistence:
    enabled: true
    size: 100Gi
    storageClass: ""

  # Qdrant configuration
  config:
    storage:
      on_disk_payload: true
    optimizers:
      default_segment_number: 4
      memmap_threshold: 20000
    service:
      grpc_port: 6334
      http_port: 6333

# External Qdrant (when qdrant.enabled=false)
externalQdrant:
  host: ""
  port: 6333
  grpcPort: 6334
  apiKey: ""
  existingSecret: ""
```

### Object Storage Configuration

```yaml
# Internal MinIO
minio:
  enabled: true
  mode: standalone

  rootUser: admin
  rootPassword: ""
  existingSecret: ""

  resources:
    requests:
      cpu: 500m
      memory: 1Gi

  persistence:
    enabled: true
    size: 200Gi

  buckets:
    - name: documents
      policy: none
    - name: exports
      policy: none

# External S3 (when minio.enabled=false)
externalS3:
  endpoint: ""
  region: us-east-1
  bucket: leasingops
  accessKey: ""
  secretKey: ""
  existingSecret: ""
  forcePathStyle: false  # Set true for MinIO/S3-compatible
```

### AI Provider Configuration

```yaml
ai:
  # Primary LLM provider: anthropic, openai, or openshift-ai
  provider: "anthropic"

  # Model selection
  model: "claude-sonnet-4-20250514"
  embeddingModel: "voyage-3"

  # Temperature for generation
  temperature: 0.1

  # Maximum tokens for response
  maxTokens: 4096

  # Retry configuration
  retries: 3
  retryDelay: 1000

  # Rate limiting
  rateLimit:
    requestsPerMinute: 100
    tokensPerMinute: 100000

  # Caching
  cache:
    enabled: true
    ttlSeconds: 3600

  # OpenShift AI configuration
  openshiftAI:
    enabled: false

    # Inference service name
    servingRuntime: "vllm"

    # Model to deploy
    modelName: "mistral-7b-instruct"

    # Model serving endpoint (auto-configured if using OpenShift AI)
    endpoint: ""

    # GPU configuration
    gpu:
      enabled: true
      count: 1
      type: "nvidia.com/gpu"

    # Resources for model serving
    resources:
      requests:
        cpu: 4
        memory: 16Gi
      limits:
        cpu: 8
        memory: 32Gi
```

---

## Environment Variables

### Core Application Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `NEIO_LICENSE_TOKEN` | NeIO license token | - | Yes |
| `DATABASE_URL` | PostgreSQL connection string | Auto | No |
| `REDIS_URL` | Redis connection string | Auto | No |
| `QDRANT_URL` | Qdrant connection string | Auto | No |
| `S3_ENDPOINT` | Object storage endpoint | Auto | No |
| `LOG_LEVEL` | Logging level | `INFO` | No |
| `ENVIRONMENT` | Environment name | `production` | No |

### AI Provider Variables

| Variable | Description | Required When |
|----------|-------------|---------------|
| `ANTHROPIC_API_KEY` | Anthropic API key | `ai.provider=anthropic` |
| `OPENAI_API_KEY` | OpenAI API key | `ai.provider=openai` |
| `VOYAGE_API_KEY` | Voyage AI embedding key | Always |
| `OPENSHIFT_AI_ENDPOINT` | OpenShift AI endpoint | `ai.openshiftAI.enabled=true` |

### Security Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `JWT_SECRET_KEY` | JWT signing key | Auto-generated |
| `JWT_ALGORITHM` | JWT algorithm | `HS256` |
| `JWT_EXPIRATION_HOURS` | Token expiration | `24` |
| `CORS_ORIGINS` | Allowed CORS origins | `*` |
| `TRUSTED_PROXIES` | Trusted proxy IPs | - |

### Performance Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORKERS_PER_CORE` | Uvicorn workers | `2` |
| `MAX_WORKERS` | Maximum workers | `8` |
| `WORKER_CONCURRENCY` | Celery concurrency | `4` |
| `DB_POOL_SIZE` | Database pool size | `20` |
| `DB_POOL_OVERFLOW` | Pool overflow | `10` |
| `REDIS_POOL_SIZE` | Redis pool size | `10` |

### Feature Flag Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FEATURE_CHAT_ENABLED` | Enable chat feature | `true` |
| `FEATURE_REPORTS_ENABLED` | Enable reporting | `true` |
| `FEATURE_NOTIFICATIONS_ENABLED` | Enable notifications | `true` |
| `FEATURE_RISK_SCORING_ENABLED` | Enable risk scoring | `true` |

---

## Secret Management

### Recommended Secret Structure

```yaml
# ai-credentials Secret
apiVersion: v1
kind: Secret
metadata:
  name: ai-credentials
  namespace: leasingops
type: Opaque
stringData:
  ANTHROPIC_API_KEY: "sk-ant-..."
  VOYAGE_API_KEY: "pa-..."
  OPENAI_API_KEY: "sk-..."  # Optional

---
# db-credentials Secret
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: leasingops
type: Opaque
stringData:
  POSTGRES_PASSWORD: "strong-password-here"
  POSTGRES_USER: "leasingops"

---
# app-secrets Secret
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: leasingops
type: Opaque
stringData:
  JWT_SECRET_KEY: "64-char-random-string"
  ENCRYPTION_KEY: "32-char-encryption-key"
```

### Using External Secret Operators

**External Secrets Operator:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ai-credentials
  namespace: leasingops
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: ai-credentials
  data:
    - secretKey: ANTHROPIC_API_KEY
      remoteRef:
        key: secret/leasingops/ai
        property: anthropic_api_key
    - secretKey: VOYAGE_API_KEY
      remoteRef:
        key: secret/leasingops/ai
        property: voyage_api_key
```

**HashiCorp Vault Agent:**

```yaml
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "leasingops"
        vault.hashicorp.com/agent-inject-secret-ai: "secret/leasingops/ai"
```

---

## Feature Flags

Feature flags allow you to enable/disable functionality without redeployment.

### Configuration via Values

```yaml
features:
  # Chat and Q&A functionality
  chat:
    enabled: true
    streamingEnabled: true

  # Document processing
  documents:
    enabled: true
    ocrEnabled: true
    maxSizeMB: 100

  # AI Agents
  agents:
    contractIntake: true
    termExtractor: true
    obligationMapper: true
    complianceChecker: true
    maintenanceScheduler: true
    returnConditionAnalyzer: true
    financialCalculator: true
    riskAssessor: true
    documentGenerator: true
    notificationOrchestrator: true

  # Notifications
  notifications:
    email: true
    slack: false
    teams: false
    webhooks: true

  # Reporting
  reports:
    enabled: true
    scheduledReports: true
    exportFormats:
      - pdf
      - excel
      - csv

  # Advanced features
  advanced:
    riskScoring: true
    predictiveAnalytics: false
    multiLanguage: false
```

### Runtime Feature Flags

Feature flags can also be configured at runtime via the admin API:

```bash
# Enable a feature
curl -X PUT https://leasingops.example.com/api/v1/admin/features/predictiveAnalytics \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}'

# Get current feature flags
curl https://leasingops.example.com/api/v1/admin/features \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

---

## AI Provider Configuration

### Anthropic (Claude)

```yaml
ai:
  provider: "anthropic"
  model: "claude-sonnet-4-20250514"

  anthropic:
    # API configuration
    baseUrl: "https://api.anthropic.com"
    apiVersion: "2023-06-01"

    # Model parameters
    temperature: 0.1
    maxTokens: 4096
    topP: 0.95

    # Retry configuration
    retries: 3
    timeout: 120
```

### OpenAI (GPT)

```yaml
ai:
  provider: "openai"
  model: "gpt-4o"

  openai:
    baseUrl: "https://api.openai.com/v1"

    # Model parameters
    temperature: 0.1
    maxTokens: 4096
    topP: 0.95
    frequencyPenalty: 0.0
    presencePenalty: 0.0
```

### OpenShift AI (Local LLM)

```yaml
ai:
  provider: "openshift-ai"

  openshiftAI:
    enabled: true

    # Serving runtime
    servingRuntime: "vllm"  # or "llama-stack", "llm-d"

    # Model configuration
    modelName: "mistral-7b-instruct"
    modelPath: "s3://models/mistral-7b/"

    # Endpoint (auto-discovered if not specified)
    endpoint: ""

    # Model serving configuration
    serving:
      # GPU configuration
      gpu:
        enabled: true
        count: 1
        type: "nvidia.com/gpu"

      # Resource limits
      resources:
        requests:
          cpu: 4
          memory: 16Gi
        limits:
          cpu: 8
          memory: 32Gi

      # vLLM specific options
      vllm:
        tensorParallelSize: 1
        maxModelLen: 8192
        quantization: "awq"  # or "gptq", null for fp16

      # Scaling
      minReplicas: 1
      maxReplicas: 3
      targetUtilization: 80
```

### Embedding Configuration

```yaml
ai:
  embedding:
    # Provider: voyage, openai, or local
    provider: "voyage"
    model: "voyage-3"

    # Batch configuration
    batchSize: 32
    maxConcurrent: 4

    # Dimension (model-dependent)
    dimension: 1024

    # Local embedding (for air-gapped)
    local:
      enabled: false
      modelPath: "/models/embeddings"
```

---

## Example Configurations

### Development Environment

```yaml
# values-development.yaml
global:
  domain: "leasingops.dev.local"
  storageClass: "standard"

app:
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 256Mi

api:
  replicaCount: 1
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
  env:
    logLevel: "DEBUG"

worker:
  replicaCount: 1
  concurrency: 2

postgresql:
  primary:
    persistence:
      size: 10Gi

redis:
  master:
    persistence:
      size: 1Gi

qdrant:
  persistence:
    size: 10Gi
```

### Production Environment

```yaml
# values-production.yaml
global:
  domain: "leasingops.example.com"
  storageClass: "gp3"

app:
  replicaCount: 3
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 10

api:
  replicaCount: 5
  autoscaling:
    enabled: true
    minReplicas: 5
    maxReplicas: 20
  resources:
    requests:
      cpu: 4
      memory: 8Gi
    limits:
      cpu: 8
      memory: 16Gi

worker:
  replicaCount: 3
  autoscaling:
    enabled: true
  concurrency: 8

postgresql:
  architecture: replication
  primary:
    persistence:
      size: 200Gi
  readReplicas:
    replicaCount: 2

redis:
  architecture: replication

qdrant:
  replicaCount: 3
  persistence:
    size: 500Gi
```

### Air-Gapped Environment

```yaml
# values-airgapped.yaml
global:
  imageRegistry: "internal-registry.example.com"
  imagePullSecrets:
    - internal-registry-secret

ai:
  provider: "openshift-ai"
  openshiftAI:
    enabled: true
    servingRuntime: "vllm"
    modelName: "mistral-7b-instruct"

  embedding:
    provider: "local"
    local:
      enabled: true
      modelPath: "/models/bge-large-en"

# Disable external dependencies
externalDependencies:
  allowExternalAI: false
  allowTelemetry: false
```

---

## Next Steps

- [Installation Guide](./INSTALLATION.md) - Install NeIO LeasingOps
- [Troubleshooting](./TROUBLESHOOTING.md) - Common issues and solutions
- [Security Guide](./SECURITY.md) - Security configuration
- [Air-Gapped Deployment](./AIRGAPPED.md) - Offline installation
