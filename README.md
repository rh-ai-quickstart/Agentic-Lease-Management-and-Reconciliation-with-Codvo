# NeIO LeasingOps on OpenShift

NeIO LeasingOps is an aircraft-lease document pipeline. Users upload PDF contracts and the platform runs them through ten AI agents that extract terms, map obligations, calculate reserves, detect variance, assess return readiness, and produce a decision recommendation.

This repository is the Helm chart and sample contracts for running it on OpenShift 4.19 or later. The chart deploys the application (frontend, API, background worker) and its PostgreSQL and Redis. Granite is served separately by the Red Hat AI Architecture charts (vLLM + LlamaStack).

Stack:

- Next.js 15 frontend
- FastAPI backend
- Python background worker (Redis job queue)
- vLLM + LlamaStack serving IBM Granite 3.3 2B
- PostgreSQL 15
- Redis 7

## Before you start

You need:

- An OpenShift 4.19+ cluster with `cluster-admin` or namespace `admin`.
- The OpenShift AI Operator installed (version 3.4 or later). It provides KServe, which serves the Granite model in step 2.
- Three worker nodes with 8 CPU / 32 GB each, one of them a GPU node for Granite inference. CPU-only is possible but slow; see Appendix A.
- `oc` and `helm` 3.x on your machine.
- ACR pull credentials for `rhleasingopsacr.azurecr.io`. Email `bala@codvo.ai` or `indranil@codvo.ai`. You will be sent a username and a password; you use both in step 3.

You do not need a Hugging Face token. The model, `ibm-granite/granite-3.3-2b-instruct`, is Apache 2.0 and not gated.

## 1. Create the namespace

```
oc new-project leasingops
```

Every command below uses `-n leasingops`.

## 2. Deploy the model server

Granite runs on the GPU through vLLM, fronted by LlamaStack. Both come from the Red Hat AI Architecture charts.

```
helm repo add rh-ai-quickstart https://rh-ai-quickstart.github.io/ai-architecture-charts
helm repo update
```

Install vLLM with Granite 3.3 2B on the GPU:

```
helm install llm-inference rh-ai-quickstart/llm-service \
  --version 0.5.9 \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct" \
  --set "models.granite-3-3-2b-instruct.device=gpu"
```

If your GPU nodes carry a taint, add the matching toleration, for example:

```
  --set "deviceConfigs.gpu.tolerations[0].key=nvidia.com/gpu" \
  --set "deviceConfigs.gpu.tolerations[0].operator=Exists" \
  --set "deviceConfigs.gpu.tolerations[0].effect=NoSchedule"
```

KServe creates the vLLM pod as `granite-3-3-2b-instruct-predictor-*`. The first start downloads the model and takes a few minutes. Wait for it:

```
oc wait --for=condition=Ready pod \
  -l serving.kserve.io/inferenceservice=granite-3-3-2b-instruct \
  -n leasingops --timeout=600s
```

Install LlamaStack pointed at the vLLM Service:

```
helm install llamastack rh-ai-quickstart/llama-stack \
  --version 0.7.3 \
  --namespace leasingops \
  --set pgvector.enabled=false \
  --set models.remote-llm.enabled=true \
  --set models.remote-llm.url=http://granite-3-3-2b-instruct-vllm:80/v1

oc rollout status deploy/llamastack -n leasingops --timeout=300s
```

That is the whole model server. The LeasingOps chart in step 4 connects to LlamaStack and registers the Granite model for you.

## 3. Create the secrets

Two secrets: one to pull the application images, one for the application's own credentials.

**Image pull secret.** Use the username and password Codvo sent you:

```
oc create secret docker-registry acr-pull-secret \
  --docker-server=rhleasingopsacr.azurecr.io \
  --docker-username='<USERNAME>' \
  --docker-password='<PASSWORD>' \
  -n leasingops
```

Quote both values. ACR tokens contain characters the shell would otherwise expand.

**Application secret.** This holds the database, cache, JWT, and demo-login credentials. The chart deploys its own PostgreSQL and Redis using these same values, so you can pick any password here; nothing external needs to match:

```
oc create secret generic neio-leasingops-secrets \
  --from-literal=POSTGRES_USER=leasingops \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=REDIS_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=DEMO_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)" \
  --from-literal=ANTHROPIC_API_KEY='' \
  -n leasingops
```

`DEMO_PASSWORD` is the password for the bundled `demo@leasingops.ai` login. You retrieve it in step 5. `ANTHROPIC_API_KEY` can stay empty; it is only used for an optional Claude fallback path.

For a GitOps deployment you would ship this secret as a `SealedSecret` instead of creating it imperatively. See Appendix C.

## 4. Install LeasingOps

```
git clone https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo.git
cd Agentic-Lease-Management-and-Reconciliation-with-Codvo
```

The chart needs your cluster's apps domain for the Route hostnames. Generate the overrides file with the domain filled in automatically:

```
cat > leasingops-overrides.yaml <<EOF
global:
  imagePullSecrets:
    - acr-pull-secret
api:
  route:
    host: api-leasingops.$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')
app:
  route:
    host: leasingops.$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')
EOF
```

Install:

```
helm install neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  --set api.image.repository=rhleasingopsacr.azurecr.io/leasingops-api \
  --set api.image.tag=20260515.01.0001 \
  --set app.image.repository=rhleasingopsacr.azurecr.io/leasingops-app \
  --set app.image.tag=20260521.01.0002 \
  --set worker.image.repository=rhleasingopsacr.azurecr.io/leasingops-worker \
  --set worker.image.tag=20260515.01.0001 \
  --set llamastack.url=http://llamastack:8321 \
  --set llamastack.model=remote-llm/ibm-granite/granite-3.3-2b-instruct \
  --set llamastack.maxTokens=2048 \
  -f leasingops/helm/values-openshift.yaml \
  -f leasingops-overrides.yaml
```

That one command deploys everything: the frontend, API, worker, PostgreSQL, and Redis, plus the ServiceAccount and the SCC binding the application images need on OpenShift. A post-install job registers the Granite model with LlamaStack.

The image tags above are the validated build. Newer tags may exist; ask Codvo before changing them.

## 5. Verify and log in

Wait for the application pods, then check them:

```
oc rollout status deploy/neio-leasingops-api -n leasingops --timeout=300s
oc rollout status deploy/neio-leasingops-app -n leasingops --timeout=300s
oc rollout status deploy/neio-leasingops-worker -n leasingops --timeout=300s
oc get pods -n leasingops
```

All pods should be `Running`. API health:

```
curl -k "https://$(oc get route neio-leasingops-api -n leasingops -o jsonpath='{.spec.host}')/health"
```

Expected: `{"status":"healthy","version":"1.0.0",...}`.

Run the bundled smoke test, which logs in, uploads a document, and confirms the pipeline picks it up:

```
helm test neio-leasingops -n leasingops --timeout 5m
```

Get the frontend URL and the demo password:

```
echo "https://$(oc get route neio-leasingops-app -n leasingops -o jsonpath='{.spec.host}')"

oc get secret neio-leasingops-secrets -n leasingops \
  -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d
```

Open the frontend URL and log in as `demo@leasingops.ai` with that password.

## 6. Walk through the application

For a fuller, screen-by-screen guide to the features (document processing, the NeIO Assistant, and the dashboards), see [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

The left sidebar groups the application into Command, Operations, Processing, and Administration. Here is a tour that exercises the whole pipeline end to end.

1. **Upload a contract.** Go to **Operations > Fleet Portfolio**. Click **Upload**, pick a PDF from `examples/sample-contracts/`, and confirm. The upload card shows the pipeline working: it names each agent as it runs, from Contract Intake through Escalation.
2. **Watch the agents run in sequence.** Open **Processing > Pipeline** while the document processes. This is the live stage view: each of the ten agents lights up in order as the worker completes it. On a GPU the full run takes roughly a minute per document.
3. **Read the extracted terms.** When the run finishes, open the document from Fleet Portfolio, or go to **Processing > Term Extraction**. This is where the Term Extractor's output lands: dates, financials, parties, aircraft details, and conditions pulled from the contract.
4. **Check return readiness.** Go to **Operations > Return Readiness**. The Return Readiness agent's redelivery gap analysis and cost estimates show here.
5. **See the decision and any escalations.** **Command > Decisions** shows the return/extend/buyout recommendation with its risk rationale. **Command > Escalations** lists anything the pipeline routed to a stakeholder. **Processing > Evidence Packs** assembles the audit-ready bundle for a document.
6. **Ask the assistant.** Click the **NeIO Assistant** button (bottom right of any screen) and ask a question about the contract you uploaded, for example "When does this lease expire?" or "What are the maintenance reserve obligations?". The assistant answers from the extracted data.
7. **Review the audit trail.** **Administration > Audit Trail** records the activity for the workspace, including the documents you uploaded.

The repository ships sample lease documents across ten document types in `examples/sample-contracts/`. Upload one to try the pipeline, or several to see the Fleet Portfolio fill up.

## Demo mode versus production mode

The application runs in one of two processing modes, set per workspace under **Administration > Settings**:

- **Production mode (the default).** Uploads run the real pipeline: Docling extracts the PDF, then the ten agents process it through the background worker. This is what the quickstart's model server is for. Agent progress, audit events, and downstream pages (Decisions, Return Readiness, Evidence Packs) all reflect real results. A document takes roughly a minute per run on a GPU.
- **Demo mode.** Uploads skip the worker and the model entirely: the API writes synthetic extraction data immediately and the document jumps straight to "extracted". Useful for a fast UI tour when you have no GPU or no worker, but it does not exercise the agents and it does not write audit events, so the Audit Trail and Pipeline pages stay empty. If you switch to demo mode, expect those screens to look inactive; that is the mode, not a bug.

Leave it on production for a real walkthrough. Switch to demo only when you explicitly want the instant, synthetic path.

## The ten agents

Documents flow through these in order:

1. Contract Intake: validates the upload and classifies the document type.
2. Term Extractor: pulls out dates, financials, parties, aircraft details, conditions.
3. Obligation Mapper: identifies contractual obligations with deadlines and owners.
4. Utilization Reconciler: compares actual flight hours and cycles against the MRO data.
5. Reserve Calculator: tracks maintenance reserve balances, contributions, drawdowns, shortfalls.
6. Variance Detector: flags discrepancies between contract terms and actual performance.
7. Return Readiness: assesses redelivery compliance, produces gap analysis and cost estimates.
8. Evidence Pack: assembles audit-ready documentation linking evidence to contract clauses.
9. Decision Support: produces return/extend/buyout analysis with risk-adjusted recommendations.
10. Escalation: routes high-severity items to stakeholders with full context.

## Architecture

```
OpenShift namespace: leasingops

  neio-leasingops-app     (Next.js 15, proxies /api/* to the API)
          |
  neio-leasingops-api     (FastAPI)
          |
          |-- neio-leasingops-worker  (reads Redis queues, writes to PostgreSQL)
          |-- neio-leasingops-postgresql
          |-- neio-leasingops-redis
          |-- uploads PVC (shared by API and worker)
          |
  llamastack  <-->  vllm  (Granite 3.3 2B on GPU)
```

The browser talks only to the frontend. The frontend proxies API calls to the backend in-cluster, so no backend URL is baked into anything and one image set works on any cluster.

## Appendix A: CPU instead of GPU

If you have no GPU node, install vLLM on CPU. Inference is much slower (around 40 seconds per agent call), acceptable for a demo but not for load testing.

```
helm install llm-inference rh-ai-quickstart/llm-service \
  --version 0.5.9 \
  --namespace leasingops \
  --set device=cpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct"
```

Everything else in the quickstart is identical.

## Appendix B: External PostgreSQL or Redis

The chart deploys its own single-replica PostgreSQL and Redis by default, which suits a quickstart. For a managed database or an existing Redis, disable the in-cluster ones and point the chart at yours:

```
  --set database.deployInCluster=false \
  --set database.external.host=<your-postgres-host> \
  --set cache.deployInCluster=false \
  --set cache.host=<your-redis-host>
```

The credentials still come from `neio-leasingops-secrets`. For an external database, create the `leasingops` database and user beforehand.

## Appendix C: GitOps

The chart is GitOps-ready: the ServiceAccount, SCC binding, and model registration are all chart resources, so a single ArgoCD `Application` drives the install. `examples/argocd-application.yaml` is a working manifest. For secrets, ship `neio-leasingops-secrets` as a Bitnami `SealedSecret` (encrypt with `kubeseal`, commit the result); `examples/sealed-secret.example.yaml` shows the shape.

## Clean up

To remove the quickstart and reset the cluster between demo runs, use the bundled teardown script. It is one command, idempotent, and needs no manual steps:

```
./scripts/teardown.sh            # prompts for confirmation
./scripts/teardown.sh -y         # no prompt (automation / Red Hat Demo Platform)
NAMESPACE=my-ns ./scripts/teardown.sh -y
```

It uninstalls every Helm release in the namespace (the app, plus `llamastack` and `llm-inference` if present), deletes the KServe InferenceServices and PersistentVolumeClaims, then deletes the namespace and waits for it to fully terminate, clearing stuck finalizers if the delete hangs. `make destroy` runs the same script. It does not touch cluster-scoped operators (the GPU operator, RHOAI / KServe / Knative).

## Troubleshooting

API or worker pod in `CrashLoopBackOff`: almost always a missing key in `neio-leasingops-secrets`. Confirm all six keys from step 3 are present, then `oc rollout restart deploy/neio-leasingops-worker -n leasingops`.

`helm test` fails at the login step: retrieve `DEMO_PASSWORD` (step 5) and confirm you can `curl` the API `/health` route. If health is fine but login fails, the API pod may not have restarted after a secret change; `oc rollout restart deploy/neio-leasingops-api -n leasingops`.

A document stops partway through the pipeline: check the worker log, `oc logs deploy/neio-leasingops-worker -n leasingops --tail=100`. It prints a heartbeat every few cycles and a timing line per LLM call, so a stall is visible.

The Audit Trail or agent progress looks empty after an upload: confirm the workspace is in production mode under **Administration > Settings**. Demo mode writes synthetic data without running the worker, so it produces no audit events and no live agent progress.

The assistant gives an answer that disagrees with the contract: the default model is Granite 3.3 2B, a small model chosen so the quickstart runs on modest hardware. It can misread dates and figures, for example calling a current lease expired. Treat the assistant as a drafting aid and verify against the extracted terms on the document page. For sharper answers, point LlamaStack at a larger Granite model in step 2.

vLLM pod stuck `Pending`: the GPU node is tainted and the install had no matching toleration. Re-run step 2 with the toleration flags.

## Where to get help

For access credentials or deployment questions, contact `bala@codvo.ai` or `indranil@codvo.ai`.

Repository: https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo

## License

Helm chart and deployment configuration: Apache 2.0 (see `LICENSE`). Application images are proprietary and require a registry pull token from Codvo.
