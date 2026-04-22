# NeIO LeasingOps on OpenShift

NeIO LeasingOps is an aircraft-lease document pipeline. Users upload PDF contracts and the platform runs them through ten AI agents that extract terms, map obligations, calculate reserves, detect variance, assess return readiness, and produce a decision recommendation.

This repository contains the Helm chart and sample contracts for running it on OpenShift 4.14 or later.

Stack:

- Next.js 15 frontend
- FastAPI backend
- Python background worker (Redis job queue)
- vLLM + LlamaStack serving IBM Granite 3.3 2B (CPU or GPU)
- PostgreSQL 15
- Redis 7

## Before you start

You need:

- An OpenShift 4.14+ cluster, either the Red Hat partner lab or a local CRC. Three worker nodes at 8 CPU / 32 GB each is enough for CPU inference.
- `cluster-admin` or namespace `admin` on that cluster.
- `oc` and `helm` 3.x installed locally.
- PostgreSQL 15 and Redis 7 (either external or deployed in-cluster; the Bitnami charts used as subcharts will install both if you don't already have them).
- ACR pull credentials for `rhleasingopsacr.azurecr.io`. Email `bala@codvo.ai` or `indranil@codvo.ai` to get a fresh token. The token is short-lived (24 hours), so request it right before you start.

You do not need a Hugging Face token. The default model is `ibm-granite/granite-3.3-2b-instruct`, which is Apache 2.0 and not gated.

You do not need a NeIO license token. Previous versions of this README referenced one; it is no longer required.

## 1. Log in to OpenShift and the registry

```
oc login --token=... --server=...
docker login rhleasingopsacr.azurecr.io -u partner-pull-token -p <PASSWORD>
```

Replace `<PASSWORD>` with the ACR token you received. The `docker login` step is only needed if you want to pull images locally; the cluster uses a pull secret (created in step 4).

## 2. Create the namespace

```
oc new-project leasingops
```

Everything below assumes `-n leasingops`.

## 3. Deploy vLLM and LlamaStack

Add the Red Hat AI Architecture Charts repo:

```
helm repo add rh-ai-quickstart https://rh-ai-quickstart.github.io/ai-architecture-charts
helm repo update
```

Install vLLM with Granite 3.3 2B on CPU:

```
helm install llm-inference rh-ai-quickstart/llm-service \
  --namespace leasingops \
  --set device=cpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct"
```

Wait for the vLLM pod to reach `Running`. First pull downloads the model and takes around five minutes.

```
oc get pods -n leasingops | grep vllm
```

Install LlamaStack pointed at vLLM:

```
helm install llamastack rh-ai-quickstart/llama-stack \
  --namespace leasingops \
  --set vllm.url=http://granite-3-3-2b-instruct-vllm:8080
```

Confirm LlamaStack is ready and the model is registered. LlamaStack adds a `remote-llm/` prefix when it registers the model:

```
oc rollout status deploy/llamastack -n leasingops --timeout=300s

curl http://$(oc get route llamastack -n leasingops -o jsonpath='{.spec.host}')/v1/models | python3 -m json.tool
```

You should see `remote-llm/ibm-granite/granite-3.3-2b-instruct` in the output. The chart uses that exact prefixed name in step 5.

The correct inference path is `/v1/chat/completions`. Some older docs mention `/v1/openai/v1/chat/completions`; that path returns 404 and must not be used.

## 4. Create the ACR pull secret

```
oc create secret docker-registry acr-pull-secret \
  --docker-server=rhleasingopsacr.azurecr.io \
  --docker-username=partner-pull-token \
  --docker-password='<PASSWORD>' \
  -n leasingops
```

Quote the password. ACR tokens contain `$` and other characters the shell will try to expand.

## 5. Create the application secret

The Helm release is named `neio-leasingops`, so the chart looks for a secret called `neio-leasingops-secrets` in the same namespace. Create it before you install the chart:

```
oc create secret generic neio-leasingops-secrets \
  --from-literal=POSTGRES_USER=leasingops \
  --from-literal=POSTGRES_PASSWORD='<DB_PASSWORD>' \
  --from-literal=REDIS_PASSWORD='<REDIS_PASSWORD>' \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=ANTHROPIC_API_KEY='' \
  -n leasingops
```

A few notes on these fields:

- `POSTGRES_USER` and `POSTGRES_PASSWORD` are the credentials the API and worker use to connect to Postgres. If you are using an external database, make sure the database `leasingops` already exists and the user can connect to it.
- `REDIS_PASSWORD` is optional. Omit the line if your Redis is unauthenticated.
- `JWT_SECRET_KEY` must be present. `openssl rand -hex 32` generates a strong one.
- `ANTHROPIC_API_KEY` is required by the schema but unused when LlamaStack is the active provider. You can leave it empty. If you want a Claude fallback path, put a real key here.

If your Postgres is in-cluster via the Bitnami subchart, the host is set automatically. If it is external, set `database.external.host` in values (see section 7).

## 6. Install the chart

```
git clone https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo.git
cd Agentic-Lease-Management-and-Reconciliation-with-Codvo

helm install neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  --set global.imagePullSecrets[0]=acr-pull-secret \
  --set api.image.repository=rhleasingopsacr.azurecr.io/leasingops-api \
  --set api.image.tag=20260331.01.0003 \
  --set app.image.repository=rhleasingopsacr.azurecr.io/leasingops-app \
  --set app.image.tag=20260331.01.0002 \
  --set worker.image.repository=rhleasingopsacr.azurecr.io/leasingops-worker \
  --set worker.image.tag=20260401.01.0003 \
  --set llamastack.url=http://llamastack:8321 \
  --set llamastack.model=remote-llm/ibm-granite/granite-3.3-2b-instruct \
  --set llamastack.maxTokens=2048 \
  -f leasingops/helm/values-openshift.yaml
```

The image tags above are the ones validated in the Red Hat partner lab. Newer tags may exist; ask before changing them.

`llamastack.maxTokens` is capped at 2048 because Granite 3.3 2B has an 8192 token context and the agent prompts already consume 4–5 k tokens. Going higher causes context overflow errors.

## 7. Verify everything is up

```
oc get pods -n leasingops
```

You should see pods similar to these, all `Running`:

```
granite-3-3-2b-instruct-predictor-xxxx        Running
llamastack-xxxx                                Running
neio-leasingops-api-xxxx                       Running (2 replicas)
neio-leasingops-app-xxxx                       Running (2 replicas)
neio-leasingops-worker-xxxx                    Running
postgresql-xxxx                                Running
redis-xxxx                                     Running
```

API health check:

```
curl https://$(oc get route neio-leasingops-api -n leasingops -o jsonpath='{.spec.host}')/health
```

Expected response: `{"status":"healthy","version":"1.0.0",...}`.

Get the frontend URL:

```
echo "https://$(oc get route neio-leasingops-app -n leasingops -o jsonpath='{.spec.host}')"
```

## 8. Log in and upload documents

Open the frontend URL in a browser and log in with the demo credentials:

```
Email:    demo@leasingops.ai
Password: EVFbYx@RPt5NnpEZ
```

Upload one of the sample PDFs from `examples/sample-contracts/` and watch it progress through the pipeline. Results appear in the document detail view as each agent completes.

The repository ships 45 real-looking lease documents across ten document types (lease agreements, delivery condition reports, MRCs, return condition reports, amendments, letters of intent, insurance certificates, technical acceptance reports, default notices, supplemental rent statements). You can upload a single document to smoke-test or the full set to load-test.

On CPU each agent takes about 40 seconds per document. A full run of 45 documents across ten agents is around 4.5 hours.

## The ten agents

Documents flow through these in order:

1. Contract Intake: validates the upload and classifies the document type (dry lease, wet lease, MRC, amendment, and so on).
2. Term Extractor: pulls out dates, financials, parties, aircraft details, conditions.
3. Obligation Mapper: identifies contractual obligations along with their deadlines and owners.
4. Utilization Reconciler: compares actual flight hours and cycles against the MRO data.
5. Reserve Calculator: tracks maintenance reserve balances, contributions, drawdowns, and shortfalls.
6. Variance Detector: flags discrepancies between contract terms and actual performance.
7. Return Readiness: assesses redelivery compliance and produces gap analysis and cost estimates.
8. Evidence Pack: assembles audit-ready documentation that links evidence back to contract clauses.
9. Decision Support: produces return/extend/buyout analysis with risk-adjusted recommendations.
10. Escalation: routes high-severity items to stakeholders with full context.

## Architecture

```
OpenShift namespace: leasingops

  neio-leasingops-app     (Next.js 15, port 3000)
          |
  neio-leasingops-api     (FastAPI, port 8001)
          |
          |------ neio-leasingops-worker
          |       (reads Redis queues, writes results to PostgreSQL)
          |
          |------ postgresql  (external or in-cluster)
          |------ redis       (external or in-cluster)
          |------ uploads PVC (5Gi, shared by API and worker)
          |
  llamastack:8321  <---->  vllm:8080  (Granite 3.3 2B)
```

The worker calls `http://llamastack:8321/v1/chat/completions`. The API and worker share a ReadWriteOnce PVC named `leasingops-uploads` for uploaded PDFs. OpenShift's restricted SCC requires `fsGroup: 1000` for that PVC, which the chart sets.

## Moving to GPU

To switch the same deployment from CPU to GPU inference, upgrade the LLM chart:

```
helm upgrade llm-inference rh-ai-quickstart/llm-service \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct" \
  --set "models.granite-3-3-2b-instruct.device=gpu"
```

For better output quality, switch to the 8B model. Same license, needs a GPU with around 20 GB of memory:

```
helm upgrade llm-inference rh-ai-quickstart/llm-service \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-8b-instruct.enabled=true" \
  --set "models.granite-3-3-8b-instruct.id=ibm-granite/granite-3.3-8b-instruct"

oc set env deployment/neio-leasingops-worker \
  LLAMASTACK_MODEL=remote-llm/ibm-granite/granite-3.3-8b-instruct \
  -n leasingops
```

## Troubleshooting

Worker pod in `CrashLoopBackOff`: the `neio-leasingops-secrets` secret is missing or missing a required key. Re-run step 5 and restart the worker (`oc rollout restart deploy/neio-leasingops-worker -n leasingops`).

`NOAUTH Authentication required` from Redis: the password is not being included in the connection URL. Verify the `REDIS_PASSWORD` key exists in the secret, or omit the value entirely if your Redis has no password.

404 on LLM calls: `LLAMASTACK_URL` is wrong. It should be exactly `http://llamastack:8321` with no trailing path. The chart builds the `/v1/chat/completions` suffix internally.

"Model not found" from LlamaStack: the model ID is missing the `remote-llm/` prefix. LlamaStack registers the model with that prefix automatically (see step 3). The chart default is already correct; only override it if you are using a different model.

`max_tokens` or context-length errors: reduce `llamastack.maxTokens`. For Granite 3.3 2B, 2048 is the ceiling.

Documents stuck at `contract_intake`: you are on an older worker image. Redeploy with `worker.image.tag=20260401.01.0003` or later.

API pod gets "permission denied" on the uploads PVC: `fsGroup: 1000` is not set on the pod. The chart sets it automatically. If you are layering your own values on top, make sure you still have `api.podSecurityContext.fsGroup: 1000` and the same on the worker.

Useful commands for diagnosis:

```
oc logs -n leasingops deploy/neio-leasingops-worker --tail=100
oc logs -n leasingops deploy/neio-leasingops-api --tail=100

# Show the pending queue length for each agent
WORKER_POD=$(oc get pods -n leasingops -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')
oc exec -n leasingops $WORKER_POD -- python3 -c "
import os, redis
r = redis.from_url(os.environ['REDIS_URL'])
for a in ['contract_intake','term_extraction','obligation_mapping','utilization_reconcile',
          'reserve_calculation','variance_detection','return_readiness',
          'evidence_pack','decision_support','escalation']:
    print(f'{a}: {r.llen(f\"leasingops:jobs:pending:{a}\")}')
"
```

## RSDP deployments

On Red Hat Solution Deployment Platform clusters, `llm.url`, `llm.apiToken`, and `llm.model` are injected automatically. You do not need to install the `llm-service` or `llama-stack` charts yourself, and you do not need to set `llamastack.*` values on the `helm install`.

The chart will read the RSDP-provided values and wire them through to the worker as `LLM_URL`, `LLM_API_TOKEN`, and `LLM_MODEL`.

## Where to get help

For access tokens, image tag refreshes, or deployment questions contact `bala@codvo.ai` or `indranil@codvo.ai`.

Repository: https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo

## License

Helm chart and deployment configuration: Apache 2.0 (see `LICENSE`). Application images are proprietary and require a registry pull token from Codvo.
