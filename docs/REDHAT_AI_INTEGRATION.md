# NeIO 2.0 + Red Hat OpenShift AI Integration

## Executive Summary

**NeIO 2.0** (Next-gen Enterprise Intelligence Orchestrator) is CODVO.AI's flagship enterprise AI platform built natively on **Red Hat OpenShift AI (RHOAI)**. This document outlines how NeIO leverages the complete Red Hat AI stack to deliver production-grade, enterprise-ready AI solutions for regulated industries.

**Target Audience:** Red Hat Partners, Enterprise Architects, Technical Decision Makers

---

## 1. High-Level Architecture

```mermaid
flowchart TB
    subgraph "Enterprise Users"
        U1[Business Users]
        U2[Data Analysts]
        U3[Operations Teams]
    end

    subgraph "NeIO 2.0 Platform"
        subgraph "Application Layer"
            APP[NeIO Frontend<br/>Next.js 15]
            API[NeIO API<br/>FastAPI]
            WORKER[Background Workers]
        end

        subgraph "AI Orchestration Layer"
            AGENTS[10 AI Agents<br/>LangGraph]
            RAG[RAG Pipeline<br/>Hybrid Search]
            ROUTER[Query Router<br/>Intent Classification]
        end
    end

    subgraph "Red Hat OpenShift AI"
        subgraph "Model Serving"
            VLLM[vLLM Inference<br/>High Throughput]
            LLMD[llm-d Controller<br/>Multi-Model Routing]
            KSERVE[KServe<br/>ModelMesh]
        end

        subgraph "Model Operations"
            LLAMA[Llama Stack<br/>Guardrails & Safety]
            CATALOG[Model Catalog<br/>Registry]
            INSTRUCTLAB[InstructLab<br/>Fine-tuning]
        end

        subgraph "OpenShift Infrastructure"
            GPU[NVIDIA GPU Operator]
            MONITOR[OpenShift Monitoring]
            LOGGING[OpenShift Logging]
        end
    end

    subgraph "Data Layer"
        PG[(PostgreSQL<br/>+ pgvector)]
        QDRANT[(Qdrant<br/>Vector Store)]
        MINIO[(MinIO<br/>Object Storage)]
        REDIS[(Redis<br/>Cache)]
    end

    U1 & U2 & U3 --> APP
    APP --> API
    API --> AGENTS
    AGENTS --> ROUTER
    ROUTER --> RAG

    AGENTS --> LLMD
    LLMD --> VLLM
    VLLM --> GPU

    RAG --> QDRANT
    RAG --> PG

    LLAMA --> VLLM
    CATALOG --> VLLM

    API --> WORKER
    WORKER --> MINIO
    WORKER --> REDIS

    style APP fill:#e1f5fe
    style VLLM fill:#ffcdd2
    style LLMD fill:#ffcdd2
    style LLAMA fill:#ffcdd2
    style AGENTS fill:#c8e6c9
```

---

## 2. Red Hat OpenShift AI Services Integration

### 2.1 Service Overview

| Red Hat OpenShift AI Component | Purpose in NeIO | Integration Status |
|--------------------------------|-----------------|-------------------|
| **Red Hat OpenShift AI (RHOAI)** | AI/ML platform foundation | Integrated |
| **vLLM on OpenShift** | High-throughput LLM inference | Integrated |
| **llm-d** | Multi-model routing & load balancing | Integrated |
| **Llama Stack** | Safety guardrails & content filtering | Integrated |
| **KServe / ModelMesh** | Serverless model serving | Integrated |
| **InstructLab** | Domain-specific model tuning | Integrated |
| **Red Hat Model Catalog** | Enterprise model registry | Integrated |
| **NVIDIA GPU Operator on OpenShift** | GPU resource management | Integrated |

### 2.2 OpenShift Platform Services

| OpenShift Component | Purpose in NeIO |
|---------------------|-----------------|
| **OpenShift Routes** | TLS termination, ingress |
| **OpenShift Monitoring** | Prometheus, Grafana dashboards |
| **OpenShift Logging** | Centralized log aggregation |
| **OpenShift Pipelines** | CI/CD for model deployment |
| **OpenShift GitOps** | Infrastructure as Code |
| **OpenShift Data Foundation** | Persistent storage for MinIO |

---

## 3. Model Serving Architecture with vLLM + llm-d

```mermaid
flowchart LR
    subgraph "NeIO Application"
        A1[Agent 1<br/>Contract Intake]
        A2[Agent 2<br/>Term Extractor]
        A3[Agent 3<br/>Obligation Mapper]
        AN[Agent N<br/>...]
    end

    subgraph "llm-d Controller"
        LB[Load Balancer]
        ROUTE[Model Router]
        QUEUE[Request Queue]
    end

    subgraph "vLLM Inference Pool"
        V1[vLLM Instance 1<br/>Llama 3.3 70B]
        V2[vLLM Instance 2<br/>Llama 3.3 70B]
        V3[vLLM Instance 3<br/>Mistral 7B]
    end

    subgraph "GPU Resources"
        G1[NVIDIA A100<br/>80GB]
        G2[NVIDIA A100<br/>80GB]
        G3[NVIDIA L4<br/>24GB]
    end

    A1 & A2 & A3 & AN --> LB
    LB --> ROUTE
    ROUTE --> QUEUE
    QUEUE --> V1 & V2 & V3
    V1 --> G1
    V2 --> G2
    V3 --> G3

    style LB fill:#ffcdd2
    style V1 fill:#fff3e0
    style V2 fill:#fff3e0
    style V3 fill:#fff3e0
```

### 3.1 Why vLLM + llm-d on OpenShift?

```mermaid
flowchart TB
    subgraph "Traditional Approach"
        T1[Request 1] --> TM[Single Model Instance]
        T2[Request 2] --> TM
        T3[Request 3] --> TM
        TM --> TR[Sequential Processing<br/>High Latency]
    end

    subgraph "NeIO + Red Hat OpenShift AI"
        R1[Request 1] --> LLMD[llm-d Router]
        R2[Request 2] --> LLMD
        R3[Request 3] --> LLMD

        LLMD --> VM1[vLLM 1<br/>Continuous Batching]
        LLMD --> VM2[vLLM 2<br/>PagedAttention]
        LLMD --> VM3[vLLM 3<br/>Speculative Decoding]

        VM1 & VM2 & VM3 --> RR[Parallel Processing<br/>3-5x Throughput]
    end

    style TR fill:#ffcdd2
    style RR fill:#c8e6c9
    style LLMD fill:#e1f5fe
```

**Key Benefits of Red Hat OpenShift AI Model Serving:**

| Capability | Benefit |
|------------|---------|
| **Continuous Batching** | 3-5x higher throughput |
| **PagedAttention** | 70% GPU memory reduction |
| **llm-d Routing** | Intelligent load distribution |
| **KServe Autoscaling** | Scale-to-zero and burst handling |
| **Multi-model Support** | Right-size models per use case |

---

## 4. AI Agent Architecture

```mermaid
flowchart TB
    subgraph "NeIO AI Agents - LangGraph"
        subgraph "Document Processing"
            A1[Contract Intake Agent<br/>OCR + Classification]
            A2[Term Extractor Agent<br/>NER + Extraction]
        end

        subgraph "Analysis & Compliance"
            A3[Obligation Mapper Agent<br/>Clause Analysis]
            A4[Compliance Checker Agent<br/>Rule Validation]
            A5[Risk Assessor Agent<br/>Risk Scoring]
        end

        subgraph "Operations"
            A6[Maintenance Scheduler<br/>Predictive Planning]
            A7[Return Condition Analyzer<br/>Asset Evaluation]
            A8[Financial Calculator<br/>Cost Analysis]
        end

        subgraph "Output & Communication"
            A9[Document Generator<br/>Report Creation]
            A10[Notification Orchestrator<br/>Alert Management]
        end
    end

    subgraph "Red Hat OpenShift AI Services"
        VLLM[vLLM<br/>Inference]
        LLAMA[Llama Stack<br/>Guardrails]
        EMBED[InstructLab<br/>Embeddings]
    end

    subgraph "Data Sources"
        VDB[(Qdrant<br/>Vector Store)]
        SQL[(PostgreSQL<br/>Structured Data)]
        DOCS[(MinIO<br/>Document Store)]
    end

    A1 --> A2 --> A3
    A3 --> A4 & A5
    A4 & A5 --> A6 & A7 & A8
    A6 & A7 & A8 --> A9 --> A10

    A1 & A2 & A3 & A4 & A5 & A6 & A7 & A8 & A9 --> VLLM
    VLLM --> LLAMA

    A1 --> DOCS
    A2 & A3 --> VDB
    A4 & A5 --> SQL

    style VLLM fill:#ffcdd2
    style LLAMA fill:#ffcdd2
    style EMBED fill:#ffcdd2
```

---

## 5. Safety & Guardrails with Llama Stack

```mermaid
flowchart LR
    subgraph "User Input"
        Q[User Query]
    end

    subgraph "Llama Stack Guardrails"
        subgraph "Input Safety"
            PII[PII Detection<br/>& Redaction]
            INJECT[Prompt Injection<br/>Detection]
            TOXIC[Toxicity<br/>Filter]
        end

        subgraph "Content Policy"
            TOPIC[Topic<br/>Restrictions]
            DOMAIN[Domain<br/>Boundaries]
        end
    end

    subgraph "LLM Processing"
        VLLM[vLLM Inference<br/>Llama 3.3 70B]
    end

    subgraph "Output Safety"
        FACT[Factuality<br/>Check]
        HALLU[Hallucination<br/>Detection]
        COMPLY[Compliance<br/>Validation]
    end

    subgraph "Response"
        R[Safe Response<br/>to User]
    end

    Q --> PII --> INJECT --> TOXIC
    TOXIC --> TOPIC --> DOMAIN
    DOMAIN --> VLLM
    VLLM --> FACT --> HALLU --> COMPLY
    COMPLY --> R

    style PII fill:#fff3e0
    style INJECT fill:#fff3e0
    style TOXIC fill:#fff3e0
    style FACT fill:#c8e6c9
    style HALLU fill:#c8e6c9
    style COMPLY fill:#c8e6c9
```

### 5.1 Guardrail Configuration

| Guardrail | Purpose | NeIO Implementation |
|-----------|---------|---------------------|
| **PII Detection** | Protect sensitive data | Auto-redact SSN, credit cards, account numbers |
| **Prompt Injection** | Prevent manipulation | Block jailbreak and injection attempts |
| **Topic Restrictions** | Stay on domain | Industry-specific response boundaries |
| **Factuality Check** | Ensure accuracy | Cross-reference with source documents |
| **Hallucination Detection** | Prevent fabrication | Confidence scoring and citation validation |

---

## 6. RAG Pipeline with Red Hat OpenShift AI

```mermaid
flowchart TB
    subgraph "Document Ingestion"
        DOC[Documents<br/>PDF, DOCX, Images]
        OCR[Tesseract OCR<br/>Text Extraction]
        CHUNK[Intelligent Chunking<br/>Semantic Boundaries]
    end

    subgraph "Embedding Generation"
        subgraph "InstructLab on OpenShift"
            EMBED[Embedding Model<br/>all-MiniLM-L6-v2]
            FINETUNE[Domain Fine-tuned<br/>Embeddings]
        end
    end

    subgraph "Vector Storage"
        QDRANT[(Qdrant<br/>Vector Database)]
        PGVEC[(PostgreSQL<br/>pgvector)]
    end

    subgraph "Query Processing"
        QUERY[User Query]
        REWRITE[Query Rewriting<br/>LLM-powered]
        HYBRID[Hybrid Search<br/>Vector + BM25]
    end

    subgraph "Response Generation"
        RERANK[Cross-Encoder<br/>Reranking]
        CONTEXT[Context Assembly]
        VLLM[vLLM Generation<br/>with Citations]
    end

    DOC --> OCR --> CHUNK
    CHUNK --> EMBED --> FINETUNE
    FINETUNE --> QDRANT & PGVEC

    QUERY --> REWRITE --> HYBRID
    HYBRID --> QDRANT & PGVEC
    QDRANT & PGVEC --> RERANK
    RERANK --> CONTEXT --> VLLM

    style EMBED fill:#ffcdd2
    style FINETUNE fill:#ffcdd2
    style VLLM fill:#ffcdd2
```

---

## 7. Deployment Architecture on Red Hat OpenShift

```mermaid
flowchart TB
    subgraph "Red Hat OpenShift Cluster"
        subgraph "Ingress Layer"
            ROUTE[OpenShift Routes<br/>TLS Termination]
            LB[HAProxy<br/>Load Balancer]
        end

        subgraph "Application Namespace: neio-leasingops"
            subgraph "Frontend Pods"
                APP1[leasingops-app<br/>Replica 1]
                APP2[leasingops-app<br/>Replica 2]
            end

            subgraph "API Pods"
                API1[leasingops-api<br/>Replica 1]
                API2[leasingops-api<br/>Replica 2]
                API3[leasingops-api<br/>Replica 3]
            end

            subgraph "Worker Pods"
                W1[leasingops-worker<br/>Replica 1]
                W2[leasingops-worker<br/>Replica 2]
            end
        end

        subgraph "Red Hat OpenShift AI Namespace"
            subgraph "Model Serving"
                LLMD[llm-d Controller]
                VLLM1[vLLM Pod 1<br/>+ GPU]
                VLLM2[vLLM Pod 2<br/>+ GPU]
            end

            subgraph "Model Registry"
                CATALOG[Red Hat Model Catalog]
                MINIO_M[(MinIO<br/>Model Storage)]
            end
        end

        subgraph "Data Namespace: neio-data"
            PG[(PostgreSQL<br/>StatefulSet)]
            REDIS[(Redis<br/>Deployment)]
            QDRANT[(Qdrant<br/>StatefulSet)]
            MINIO[(MinIO<br/>StatefulSet)]
        end

        subgraph "OpenShift Monitoring"
            PROM[Prometheus]
            GRAF[Grafana]
            ALERT[AlertManager]
        end
    end

    ROUTE --> LB
    LB --> APP1 & APP2
    APP1 & APP2 --> API1 & API2 & API3
    API1 & API2 & API3 --> W1 & W2

    API1 & API2 & API3 --> LLMD
    LLMD --> VLLM1 & VLLM2

    API1 & API2 & API3 --> PG & REDIS & QDRANT
    W1 & W2 --> MINIO

    VLLM1 & VLLM2 --> MINIO_M

    API1 & API2 & API3 --> PROM
    VLLM1 & VLLM2 --> PROM

    style LLMD fill:#ffcdd2
    style VLLM1 fill:#ffcdd2
    style VLLM2 fill:#ffcdd2
```

---

## 8. Request Flow: End-to-End

```mermaid
sequenceDiagram
    participant U as User
    participant APP as NeIO Frontend
    participant API as NeIO API
    participant ROUTER as Query Router
    participant AGENT as AI Agent
    participant LLMD as llm-d
    participant VLLM as vLLM
    participant LLAMA as Llama Stack
    participant VDB as Qdrant

    U->>APP: Submit Query
    APP->>API: POST /api/v1/chat
    API->>ROUTER: Classify Intent

    ROUTER->>LLMD: Get intent classification
    LLMD->>VLLM: Inference request
    VLLM->>LLAMA: Input guardrails
    LLAMA-->>VLLM: Validated input
    VLLM-->>LLMD: Intent: "lease_analysis"
    LLMD-->>ROUTER: Route to RAG workflow

    ROUTER->>AGENT: Execute Lease Analysis Agent
    AGENT->>VDB: Hybrid search (vector + keyword)
    VDB-->>AGENT: Relevant documents

    AGENT->>LLMD: Generate response with context
    LLMD->>VLLM: LLM inference
    VLLM->>LLAMA: Output guardrails
    LLAMA-->>VLLM: Safe response
    VLLM-->>LLMD: Generated response
    LLMD-->>AGENT: Response with citations

    AGENT-->>API: Structured response
    API-->>APP: JSON response
    APP-->>U: Display answer with sources
```

---

## 9. GPU Resource Management with NVIDIA GPU Operator

```mermaid
flowchart TB
    subgraph "NVIDIA GPU Operator on OpenShift"
        DRIVER[GPU Driver<br/>DaemonSet]
        PLUGIN[Device Plugin<br/>DaemonSet]
        DCGM[DCGM Exporter<br/>Metrics]
    end

    subgraph "GPU Node Pool"
        subgraph "Node 1: A100 80GB"
            G1A[GPU 0<br/>vLLM Instance 1]
            G1B[GPU 1<br/>vLLM Instance 2]
        end

        subgraph "Node 2: A100 80GB"
            G2A[GPU 0<br/>vLLM Instance 3]
            G2B[GPU 1<br/>Available]
        end

        subgraph "Node 3: L4 24GB"
            G3A[GPU 0<br/>Embedding Model]
        end
    end

    subgraph "Resource Requests"
        VLLM1[vLLM 70B<br/>requests: 1 GPU<br/>memory: 70Gi]
        VLLM2[vLLM 7B<br/>requests: 1 GPU<br/>memory: 20Gi]
        EMB[Embeddings<br/>requests: 1 GPU<br/>memory: 8Gi]
    end

    DRIVER --> PLUGIN
    PLUGIN --> G1A & G1B & G2A & G2B & G3A
    DCGM --> PLUGIN

    VLLM1 --> G1A & G1B & G2A
    VLLM2 --> G2B
    EMB --> G3A

    style G1A fill:#c8e6c9
    style G1B fill:#c8e6c9
    style G2A fill:#c8e6c9
    style G2B fill:#fff3e0
    style G3A fill:#e1f5fe
```

---

## 10. Monitoring with OpenShift Monitoring Stack

```mermaid
flowchart TB
    subgraph "NeIO Application Metrics"
        APP_M[Request Latency<br/>Throughput<br/>Error Rates]
        AGENT_M[Agent Execution Time<br/>Token Usage<br/>Cache Hits]
    end

    subgraph "Red Hat OpenShift AI Metrics"
        VLLM_M[vLLM Metrics<br/>Tokens/sec<br/>Queue Depth<br/>Batch Size]
        GPU_M[GPU Metrics<br/>Utilization<br/>Memory<br/>Temperature]
        LLMD_M[llm-d Metrics<br/>Routing Decisions<br/>Load Distribution]
    end

    subgraph "OpenShift Monitoring Stack"
        PROM[Prometheus<br/>Metrics Collection]
        GRAF[Grafana<br/>Dashboards]
        ALERT[AlertManager<br/>Notifications]
    end

    subgraph "NeIO Dashboards"
        D1[AI Operations<br/>Dashboard]
        D2[Model Performance<br/>Dashboard]
        D3[Cost & Usage<br/>Dashboard]
    end

    APP_M & AGENT_M --> PROM
    VLLM_M & GPU_M & LLMD_M --> PROM
    PROM --> GRAF
    PROM --> ALERT
    GRAF --> D1 & D2 & D3

    style PROM fill:#ffcdd2
    style GRAF fill:#ffcdd2
```

### 10.1 Key Metrics Tracked

| Category | Metric | Alert Threshold |
|----------|--------|-----------------|
| **Latency** | P95 response time | > 2s |
| **Throughput** | Tokens per second | < 100 |
| **GPU** | Utilization | < 30% or > 95% |
| **Memory** | GPU memory usage | > 90% |
| **Errors** | LLM error rate | > 1% |
| **Queue** | Request queue depth | > 100 |

---

## 11. Security & Compliance on OpenShift

```mermaid
flowchart TB
    subgraph "Security Layers"
        subgraph "Network Security"
            TLS[TLS 1.3<br/>OpenShift Routes]
            NP[NetworkPolicies<br/>Pod Isolation]
            FW[Egress Firewall<br/>Egress Control]
        end

        subgraph "Identity & Access"
            OIDC[Red Hat SSO<br/>OIDC/SAML]
            RBAC[OpenShift RBAC<br/>Role-Based Access]
            SA[Service Accounts<br/>Workload Identity]
        end

        subgraph "Data Protection"
            ENC[Encryption at Rest<br/>OpenShift Data Foundation]
            VAULT[HashiCorp Vault<br/>Secret Management]
            PII[PII Redaction<br/>Llama Stack]
        end

        subgraph "Audit & Compliance"
            AUDIT[OpenShift Audit<br/>All API Calls]
            TRAIL[Audit Trail<br/>LLM Interactions]
            SOC2[SOC 2 Type II<br/>Compliance]
        end
    end

    TLS --> OIDC --> ENC --> AUDIT
    NP --> RBAC --> VAULT --> TRAIL
    FW --> SA --> PII --> SOC2

    style TLS fill:#e1f5fe
    style OIDC fill:#e1f5fe
    style ENC fill:#c8e6c9
    style AUDIT fill:#fff3e0
```

---

## 12. Value Proposition Summary

```mermaid
mindmap
  root((NeIO + Red Hat OpenShift AI))
    Enterprise Ready
      SOC 2 Compliant
      Air-gapped Support
      Multi-tenant
    Performance
      3-5x Throughput
      70% Memory Savings
      KServe Autoscaling
    Security
      Llama Stack Guardrails
      PII Protection
      OpenShift Audit Logging
    Flexibility
      Multi-model Support
      Hybrid Cloud
      Open Standards
    Red Hat Support
      Red Hat Certified
      24/7 Enterprise Support
      Professional Services
```

### Key Differentiators

| Capability | Without Red Hat OpenShift AI | With Red Hat OpenShift AI |
|------------|------------------------------|---------------------------|
| **Model Serving** | Custom infrastructure, high ops burden | Managed vLLM + llm-d on OpenShift |
| **Scaling** | Manual, complex | KServe autoscaling, scale-to-zero |
| **Safety** | DIY guardrails | Llama Stack built-in |
| **GPU Management** | Manual allocation | NVIDIA GPU Operator |
| **Storage** | Custom object storage | MinIO on OpenShift Data Foundation |
| **Monitoring** | Custom dashboards | OpenShift Monitoring (Prometheus/Grafana) |
| **Support** | Community only | Red Hat Enterprise 24/7 Support |
| **Compliance** | Self-certification | Red Hat Certified, OpenShift hardened |

---

## 13. Architecture Comparison: Before & After

```mermaid
flowchart LR
    subgraph "Before: Generic Cloud AI"
        B1[Third-party LLM API<br/>Per-token costs] --> B2[No Control<br/>Data leaves organization]
        B2 --> B3[Vendor Lock-in<br/>No customization]
        B3 --> B4[Compliance Risk<br/>No audit trail]
    end

    subgraph "After: NeIO + Red Hat OpenShift AI"
        A1[On-premises vLLM<br/>Predictable costs] --> A2[Full Control<br/>Data stays internal]
        A2 --> A3[Open Standards<br/>InstructLab customization]
        A3 --> A4[Enterprise Compliant<br/>Full audit trail]
    end

    B4 -.->|Migration| A1

    style B1 fill:#ffcdd2
    style B2 fill:#ffcdd2
    style B3 fill:#ffcdd2
    style B4 fill:#ffcdd2
    style A1 fill:#c8e6c9
    style A2 fill:#c8e6c9
    style A3 fill:#c8e6c9
    style A4 fill:#c8e6c9
```

---

## Contact

**CODVO.AI** - Red Hat Technology Partner

- Website: https://codvo.ai
- Email: partnerships@codvo.ai
- Red Hat Ecosystem Catalog: CODVO.AI

---

*Document Version: 1.0 | February 2025 | Prepared for Red Hat Partnership*
