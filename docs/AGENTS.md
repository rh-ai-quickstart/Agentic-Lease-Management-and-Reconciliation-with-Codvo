# AI Agents Guide

NeIO LeasingOps includes 10 specialized AI agents built with **LangGraph**. Each agent is a stateful node in the processing graph, invoked by the `leasingops-worker` service and coordinated through the `leasingops-api`.

All agents call the configured LLM endpoint (`llm.url`) via LlamaStack's OpenAI-compatible interface and read/write to shared state in PostgreSQL and Qdrant.

---

## Agent Pipeline Overview

```
Document Upload
      │
      ▼
Contract Intake Agent
      │
      ▼
Term Extractor Agent
      │
      ▼
Obligation Mapper Agent
      │
      ├──────────────────────────┐
      ▼                          ▼
Compliance Checker Agent    Risk Assessor Agent
      │                          │
      └──────────┬───────────────┘
                 │
      ┌──────────┼──────────┐
      ▼          ▼          ▼
Maintenance   Return     Financial
Scheduler    Condition  Calculator
Agent        Analyzer    Agent
      │          │          │
      └──────────┼──────────┘
                 ▼
        Document Generator Agent
                 │
                 ▼
        Notification Orchestrator Agent
```

---

## Agent Reference

### 1. Contract Intake Agent

**Purpose:** First-stage document processor. Validates incoming lease documents, classifies document type (operating lease, finance lease, wet lease, dry lease), and routes to the appropriate downstream pipeline.

**Inputs:** Raw PDF or DOCX upload
**Outputs:** Document classification, metadata extraction, quality score
**LLM usage:** OCR post-processing, classification prompt

---

### 2. Term Extractor Agent

**Purpose:** Extracts structured data from lease contracts using named entity recognition and targeted extraction prompts. Identifies key terms including dates, financial figures, asset identifiers, and party names.

**Inputs:** Classified contract document
**Outputs:** Structured JSON with extracted terms (dates, amounts, aircraft tail numbers, parties, conditions)
**LLM usage:** Multi-pass extraction with schema validation

---

### 3. Obligation Mapper Agent

**Purpose:** Identifies and categorizes all contractual obligations from extracted terms. Maps each obligation to a category (maintenance, payment, return condition, insurance, reporting) and assigns responsible parties and due dates.

**Inputs:** Extracted terms from Term Extractor Agent
**Outputs:** Obligation registry entries in PostgreSQL, vector embeddings in Qdrant
**LLM usage:** Clause analysis, obligation classification

---

### 4. Compliance Checker Agent

**Purpose:** Validates the lease contract and extracted obligations against aviation regulatory requirements (EASA, FAA, IATA) and customer-defined compliance rules. Flags gaps and generates compliance scores.

**Inputs:** Obligation registry, compliance rule set
**Outputs:** Compliance report, gap list, overall compliance score (0–100)
**LLM usage:** Rule matching, gap analysis, report generation

---

### 5. Maintenance Scheduler Agent

**Purpose:** Plans and optimizes maintenance schedules based on extracted maintenance obligations, aircraft utilization data, and MRO availability. Integrates with calendar data to avoid conflicts.

**Inputs:** Maintenance obligations, utilization forecast
**Outputs:** Maintenance schedule entries, calendar events, MRO work orders
**LLM usage:** Schedule optimization reasoning, conflict resolution

---

### 6. Return Condition Analyzer Agent

**Purpose:** Assesses aircraft return condition requirements at lease end. Compares contractual return conditions against current aircraft condition reports and estimates redelivery costs.

**Inputs:** Return condition clauses, aircraft condition data
**Outputs:** Return condition assessment, estimated redelivery cost, punch-list items
**LLM usage:** Condition comparison, cost estimation

---

### 7. Financial Calculator Agent

**Purpose:** Computes all lease financial obligations including periodic payments, maintenance reserves, security deposits, redelivery adjustments, and penalty calculations.

**Inputs:** Financial terms from Term Extractor Agent, payment history
**Outputs:** Payment schedules, reserve calculations, penalty assessments
**LLM usage:** Interpretation of financial clauses; arithmetic is handled deterministically

---

### 8. Risk Assessor Agent

**Purpose:** Evaluates contract and operational risks across financial, compliance, maintenance, and redelivery dimensions. Produces a risk matrix and highlights high-priority items for human review.

**Inputs:** Outputs from Compliance Checker, Financial Calculator, Obligation Mapper
**Outputs:** Risk matrix, risk score per category, escalation flags
**LLM usage:** Risk reasoning, narrative generation

---

### 9. Document Generator Agent

**Purpose:** Creates formatted output documents including compliance reports, maintenance notices, redelivery letters, financial statements, and regulatory filings.

**Inputs:** Agent outputs from earlier pipeline stages, output format specification
**Outputs:** PDF/DOCX documents stored in object storage (MinIO/S3)
**LLM usage:** Document drafting, formatting, professional tone adjustment

---

### 10. Notification Orchestrator Agent

**Purpose:** Final stage of the pipeline. Manages all alerts, reminders, and escalations. Sends notifications to configured channels (email, Slack, webhook) when deadlines approach or compliance issues are detected.

**Inputs:** Obligation deadlines, risk flags, compliance alerts
**Outputs:** Notification records, escalation events
**LLM usage:** Notification message drafting (optional, configurable)

---

## Configuration

Agent behavior is controlled via Helm values under the `agents:` key and environment variables passed to the worker pod.

```yaml
# values.yaml (excerpt)
worker:
  agents:
    enabled: true
    concurrency: 4            # parallel agent executions
    timeout: 300              # seconds per agent run
    retryOnFailure: true
    maxRetries: 3
```

Key environment variables:

| Variable | Description |
|----------|-------------|
| `LLM_URL` | Inference endpoint (from `llm.url`) |
| `LLM_API_TOKEN` | Bearer token (from `llm.apiToken`) |
| `LLM_MODEL` | Model name (from `llm.model`) |
| `AGENT_CONCURRENCY` | Max parallel agents |
| `AGENT_TIMEOUT` | Per-agent timeout in seconds |

---

## Related Documentation

- [Architecture Overview](ARCHITECTURE.md) — system-level design
- [Red Hat OpenShift AI Integration](REDHAT_AI_INTEGRATION.md) — LLM serving architecture
- [Configuration Reference](CONFIGURATION.md) — full Helm values reference
