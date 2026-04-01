# NeIO LeasingOps — Architecture Overview

This document describes the system as it is deployed and tested on OpenShift 4.14+ (validated on CRC with CPU-only inference).

---

## System Overview

NeIO LeasingOps is a document-processing pipeline that drives aircraft lease contracts through 10 sequential AI agents. Users upload PDF contracts; the worker processes each document through the full agent chain and surfaces structured outputs (extracted terms, obligations, variances, return readiness, decision recommendations).

All components run in a single OpenShift namespace (`leasingops`).

```mermaid
graph TB
    subgraph OCP["OpenShift Cluster — Namespace: leasingops"]
        APP[leasingops-app<br/>Next.js 15 · Port 3000]
        API[leasingops-api<br/>FastAPI · Port 8001]
        WORKER[leasingops-worker<br/>Python · Redis BRPOP queues]
        DOCLING[docling<br/>Document parsing · Port 5001]

        subgraph RHAI["In-cluster Inference (RHAI)"]
            VLLM[vllm<br/>Port 8080<br/>ibm-granite/granite-3.3-2b-instruct]
            LS[llamastack<br/>Port 8321<br/>distribution-starter]
        end

        PVC[(leasingops-uploads<br/>5Gi PVC<br/>API + Worker shared)]
    end

    subgraph HOST["VPS Host (external)"]
        PG[(PostgreSQL 15<br/>Port 5432)]
        REDIS[(Redis 7<br/>Port 6379)]
    end

    APP -->|HTTPS| API
    API -->|upload/read| PVC
    WORKER -->|read| PVC
    API -->|job enqueue| REDIS
    WORKER -->|BRPOP job queue| REDIS
    API --> PG
    WORKER --> PG
    WORKER -->|parse PDF| DOCLING
    WORKER -->|LLM calls<br/>POST /v1/openai/v1/chat/completions| LS
    LS --> OLLAMA

    style RHAI fill:#fee2e2,stroke:#dc2626
    style OCP fill:#f9fafb,stroke:#374151
```

---

## Components

### leasingops-app

Next.js 15 frontend served at the OpenShift route.

| | |
|---|---|
| **Port** | 3000 |
| **Route** | `https://leasingops.apps.<cluster-domain>` |
| **Image** | `rhleasingopsacr.azurecr.io/leasingops-app` |
| **Env** | `NEXT_PUBLIC_API_URL` → leasingops-api route |

### leasingops-api

FastAPI backend. Handles document uploads, contract CRUD, and exposes the REST API.

| | |
|---|---|
| **Port** | 8001 |
| **Route** | `https://leasingops-api.apps.<cluster-domain>` |
| **Image** | `rhleasingopsacr.azurecr.io/leasingops-api` |
| **Storage** | Mounts `leasingops-uploads` PVC at `/app/uploads` |

**Endpoints:**

| Endpoint | Purpose |
|----------|---------|
| `POST /api/v1/documents/upload` | Accept PDF, enqueue ingestion job |
| `GET /api/v1/documents` | List documents with pipeline status |
| `GET /api/v1/documents/{id}` | Document detail + agent results |
| `GET /health` | Liveness / readiness probe |

### leasingops-worker

Background processor. Polls Redis job queues and drives each document through the 10-agent pipeline sequentially.

| | |
|---|---|
| **Command** | `python worker.py` |
| **Image** | `rhleasingopsacr.azurecr.io/leasingops-worker` |
| **Storage** | Mounts `leasingops-uploads` PVC at `/app/uploads` |
| **Queue pattern** | Redis BRPOP on `leasingops:jobs:pending:{job_type}` |
| **Status key** | `leasingops:status:{doc_id}` (Redis hash) |

### vLLM (llm-service arch chart)

Runs the language model via vLLM, deployed by the [Red Hat AI Architecture Charts](https://github.com/rh-ai-quickstart/ai-architecture-charts). Serves `ibm-granite/granite-3.3-2b-instruct` by default — an Apache 2.0 open model from IBM Research, no Hugging Face token required.

| | |
|---|---|
| **Image (CPU)** | `quay.io/ecosystem-appeng/vllm:cpu-v0.9.2` |
| **Image (GPU)** | `vllm/vllm-openai:v0.11.1` |
| **Port** | 8080 |
| **Model** | `ibm-granite/granite-3.3-2b-instruct` |
| **Service name** | `granite-3-3-2b-instruct-vllm` |
| **Deployed via** | `helm install llm-inference rh-ai-quickstart/llm-service` |

### LlamaStack (llama-stack arch chart)

OpenAI-compatible API gateway over vLLM. All agent LLM calls go through LlamaStack. Deployed by the arch charts using `distribution-starter`.

| | |
|---|---|
| **Image** | `llamastack/distribution-starter:0.6.0` |
| **Port** | 8321 |
| **vLLM backend** | `http://granite-3-3-2b-instruct-vllm/v1` |
| **OpenAI-compat endpoint** | `POST /v1/openai/v1/chat/completions` |
| **Deployed via** | `helm install llamastack rh-ai-quickstart/llama-stack` |

> **Important:** The LlamaStack endpoint is at `/v1/openai/v1/chat/completions`, **not** `/v1/chat/completions`. The worker's `LLAMASTACK_URL` is set to `http://llamastack:8321` and the OpenAI client is configured with `base_url=http://llamastack:8321/v1/openai/v1`.

### Docling (optional)

Document parsing service. The worker sends PDFs to Docling for structured text extraction. Falls back to PyMuPDF automatically when Docling is unavailable — no config change needed.

| | |
|---|---|
| **Image** | `quay.io/docling-project/docling-serve` (CPU build) |
| **Port** | 5001 |
| **Fallback** | PyMuPDF (built into worker image) |

### Data Layer (external to cluster)

PostgreSQL and Redis run on the VPS host, reachable from pods via the host's public IP. CRC uses passt networking — pods reach the host at its public IP rather than a gateway address.

| Service | Default port | Used for |
|---------|-------------|----------|
| PostgreSQL 15 | 5432 | Document records, agent results, contracts |
| Redis 7 | 6379 | Job queues (`leasingops:jobs:pending:*`) and status hashes |

### Shared PVC

`leasingops-uploads` (5Gi, ReadWriteOnce) is mounted by both the API and worker at `/app/uploads`. The API writes uploaded PDFs; the worker reads them for processing.

OpenShift restricted SCC requires `fsGroup: 1000` in the pod security context for PVC write access — the chart sets this automatically.

---

## 10-Agent Pipeline

Documents are processed sequentially through 10 agents. Each agent is a Redis job type. When an agent completes, it enqueues the next agent's job.

```mermaid
graph LR
    UPLOAD[Document Upload] --> A1
    A1[contract_intake] --> A2[term_extraction]
    A2 --> A3[obligation_mapping]
    A3 --> A4[utilization_reconcile]
    A4 --> A5[reserve_calculation]
    A5 --> A6[variance_detection]
    A6 --> A7[return_readiness]
    A7 --> A8[evidence_pack]
    A8 --> A9[decision_support]
    A9 --> A10[escalation]
    A10 --> DONE[completed]
```

**Job queue pattern:**

```
Redis list:  leasingops:jobs:pending:{job_type}  ← worker BRPOP
Redis hash:  leasingops:status:{doc_id}           ← status + current_agent
Redis hash:  leasingops:jobs:{job_id}             ← job payload
```

### Agent Descriptions

| Agent | Job type | Purpose |
|-------|----------|---------|
| **Contract Intake** | `contract_intake` | Validates and classifies incoming document (dry lease, wet lease, MRC, amendment, etc.) |
| **Term Extractor** | `term_extraction` | Extracts dates, financials, parties, aircraft details, and conditions |
| **Obligation Mapper** | `obligation_mapping` | Identifies all contractual obligations with deadlines and responsible parties |
| **Utilization Reconciler** | `utilization_reconcile` | Compares actual flight hours/cycles against contracted MRO data |
| **Reserve Calculator** | `reserve_calculation` | Tracks maintenance reserve balances, contributions, drawdowns, and shortfalls |
| **Variance Detector** | `variance_detection` | Flags discrepancies between contract terms and actual performance |
| **Return Readiness** | `return_readiness` | Assesses redelivery compliance — gap analysis, cost estimates, timeline |
| **Evidence Pack** | `evidence_pack` | Assembles audit-ready documentation linking evidence to contract clauses |
| **Decision Support** | `decision_support` | Produces return/extend/buyout analysis with risk-adjusted recommendations |
| **Escalation** | `escalation` | Routes items requiring human judgment to stakeholders with full context |

---

## Document Ingestion Flow

```mermaid
sequenceDiagram
    participant User
    participant App as leasingops-app
    participant API as leasingops-api (8001)
    participant PVC as /app/uploads (PVC)
    participant Redis
    participant Worker as leasingops-worker
    participant Docling as docling (5001)
    participant LS as llamastack (8321)
    participant PG as PostgreSQL

    User->>App: Upload PDF
    App->>API: POST /api/v1/documents/upload
    API->>PVC: Write PDF to /app/uploads/{uuid}_filename.pdf
    API->>PG: Create document record (status=pending)
    API->>Redis: LPUSH leasingops:jobs:pending:upload
    API-->>App: 202 Accepted

    Worker->>Redis: BRPOP leasingops:jobs:pending:upload
    Worker->>PVC: Read PDF
    Worker->>Docling: Parse PDF (fallback: PyMuPDF)
    Docling-->>Worker: Structured text
    Worker->>Redis: Update status=processing, current_agent=contract_intake
    Worker->>Redis: LPUSH leasingops:jobs:pending:contract_intake

    loop Each agent in sequence
        Worker->>Redis: BRPOP leasingops:jobs:pending:{agent}
        Worker->>LS: POST /v1/openai/v1/chat/completions
        LS-->>Worker: LLM response
        Worker->>PG: Store agent result
        Worker->>Redis: LPUSH leasingops:jobs:pending:{next_agent}
    end

    Worker->>Redis: Update status=completed
    Worker->>PG: Update document record
```

---

## Inference Architecture

```
leasingops-worker
        │
        │  POST /v1/openai/v1/chat/completions
        ▼
llamastack:8321  (distribution-starter)
        │
        │  vLLM OpenAI API
        ▼
granite-3-3-2b-instruct-vllm:8080
        │
        ▼
ibm-granite/granite-3.3-2b-instruct  (CPU or GPU)
```

**Worker env vars:**

| Variable | Value | Description |
|----------|-------|-------------|
| `LLAMASTACK_URL` | `http://llamastack:8321` | LlamaStack service (in-cluster) |
| `LLAMASTACK_MODEL` | `ibm-granite/granite-3.3-2b-instruct` | Model ID as registered in vLLM |

**LLM call code pattern:**

```python
from openai import AsyncOpenAI

client = AsyncOpenAI(
    base_url="http://llamastack:8321/v1/openai/v1",
    api_key="llamastack",  # LlamaStack does not enforce API keys
)

response = await client.chat.completions.create(
    model="ibm-granite/granite-3.3-2b-instruct",
    messages=[...],
    temperature=0.1,
    max_tokens=4096,
)
```

---

## Deployment Architecture

### Namespace

All components deploy into the **`leasingops`** namespace.

### Pods

| Pod | Replicas | Resources (request/limit) |
|-----|----------|--------------------------|
| leasingops-app | 1 | 100m CPU / 500m · 256Mi / 512Mi |
| leasingops-api | 1 | 200m CPU / 1000m · 512Mi / 1Gi |
| leasingops-worker | 1 | 200m CPU / 1000m · 512Mi / 2Gi |
| vllm (granite-3-3-2b-instruct) | 1 | 4 CPU / 8 · 8Gi / 16Gi |
| llamastack | 1 | 100m CPU / 500m · 256Mi / 1Gi |
| docling | 1 (optional) | — |

### Storage

| PVC | Size | Access | Mounted by |
|-----|------|--------|------------|
| `leasingops-uploads` | 5Gi | ReadWriteOnce | api, worker |

### Routes (TLS edge termination)

| Route | Service | Port |
|-------|---------|------|
| `leasingops.apps.<domain>` | leasingops-app | 3000 |
| `leasingops-api.apps.<domain>` | leasingops-api | 8001 |

### Secrets

All sensitive values live in the `leasingops-secrets` Secret:

| Key | Description |
|-----|-------------|
| `LEASINGOPS_DATABASE_URL` | PostgreSQL connection string (`postgresql+asyncpg://...`) |
| `REDIS_URL` | Redis connection string (`redis://:password@host:6379`) |
| `JWT_SECRET_KEY` | 64-char random string for token signing |
| `UIP_INTERNAL_API_KEY` | Optional — inter-service auth key |

---

## Production Path (GPU)

Switch to GPU by changing `device=cpu` to `device=gpu` in the `llm-inference` Helm release. Same model, same LlamaStack config — no application changes required.

For higher quality, upgrade to `ibm-granite/granite-3.3-8b-instruct`:

```bash
helm upgrade llm-inference rh-ai-quickstart/llm-service \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-8b-instruct.enabled=true" \
  --set "models.granite-3-3-8b-instruct.id=ibm-granite/granite-3.3-8b-instruct" \
  --set "models.granite-3-3-8b-instruct.device=gpu"
```

**RSDP deployments** — `llm.url`, `llm.apiToken`, and `llm.model` are injected automatically by RSDP. No manual configuration needed.

---

## Related Docs

- [Installation Guide](./INSTALLATION.md)
- [Configuration Reference](./CONFIGURATION.md)
- [AI Agents Guide](./AGENTS.md)
- [Troubleshooting](./TROUBLESHOOTING.md)
- [Red Hat OpenShift AI Integration](./REDHAT_AI_INTEGRATION.md)

---

*NeIO LeasingOps | vLLM + LlamaStack via Red Hat AI Architecture Charts | Model: ibm-granite/granite-3.3-2b-instruct*
