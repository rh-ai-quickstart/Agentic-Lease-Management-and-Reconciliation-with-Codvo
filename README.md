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

Install vLLM with Granite 3.3 2B on CPU. Pin the chart version so future installs are reproducible:

```
helm install llm-inference rh-ai-quickstart/llm-service \
  --version 0.5.9 \
  --namespace leasingops \
  --set device=cpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct"
```

The vLLM pod is created by KServe and named `granite-3-3-2b-instruct-predictor-*`. First pull downloads the model and takes about five minutes. Wait for it to reach `Running`:

```
oc get pods -n leasingops | grep predictor
```

Install LlamaStack and wire it to the vLLM Service. Three things to get right or it silently doesn't work:

- The chart value is `models.remote-llm.enabled=true` + `models.remote-llm.url=...`. Older docs say `vllm.url=...`; that key doesn't exist in chart 0.7.x and is silently ignored.
- The vLLM Service port is `80`, not `8080`. Container internal port is 8080; the Service that the chart creates forwards on 80.
- The URL must end in `/v1`. LlamaStack's `remote::vllm` provider appends path segments directly. Without the suffix, every chat completion gets 404 from upstream.

```
helm install llamastack rh-ai-quickstart/llama-stack \
  --version 0.7.3 \
  --namespace leasingops \
  --set pgvector.enabled=false \
  --set models.remote-llm.enabled=true \
  --set models.remote-llm.url=http://granite-3-3-2b-instruct-vllm:80/v1
```

`pgvector.enabled=false` is also required. The chart's default tries to bring up an embedded pgvector PVC that the application doesn't use, and without disabling it the install fails.

Wait for the deployment to roll out:

```
oc rollout status deploy/llamastack -n leasingops --timeout=300s
```

LlamaStack does NOT auto-register models from the configured vLLM URL. The application chart in step 7 takes care of this on every install or upgrade via a post-install Helm Job (`<release>-register-model`), so you can skip ahead to step 4 and come back here for the smoke test below once the chart is installed.

If you want to confirm registration after `helm install` completes, port-forward to the LlamaStack Service and list models. LlamaStack doesn't expose an OpenShift Route by default:

```
oc port-forward -n leasingops svc/llamastack 8321:8321 &
curl -s http://localhost:8321/v1/models | python3 -m json.tool
kill %1
```

You should see `remote-llm/ibm-granite/granite-3.3-2b-instruct` in the output. The chart uses that exact prefixed name in step 6.

Optional smoke test: confirm the full path (LlamaStack → vLLM → Granite) returns a real completion:

```
oc exec -n leasingops deploy/llamastack -- python3 -c "
import urllib.request, json
body = json.dumps({
  'model': 'remote-llm/ibm-granite/granite-3.3-2b-instruct',
  'messages': [{'role':'user','content':'Reply with just OK.'}],
  'max_tokens': 16
}).encode()
req = urllib.request.Request('http://localhost:8321/v1/chat/completions', data=body, method='POST',
  headers={'Content-Type':'application/json'})
out = json.loads(urllib.request.urlopen(req).read())
print(out['choices'][0]['message']['content'])
"
```

Expected output: `OK`.

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

The Helm release is named `neio-leasingops`, so the chart looks for a Secret called `neio-leasingops-secrets` in the same namespace. There are two paths for shipping it.

**For demo and fast iteration, create it imperatively:**

```
oc create secret generic neio-leasingops-secrets \
  --from-literal=POSTGRES_USER=leasingops \
  --from-literal=POSTGRES_PASSWORD='<DB_PASSWORD>' \
  --from-literal=REDIS_PASSWORD='<REDIS_PASSWORD>' \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=ANTHROPIC_API_KEY='' \
  -n leasingops
```

**For GitOps / Red Hat Demo Platform, ship a `SealedSecret` instead.** This is the recommended path because the encrypted manifest can be committed to your fork of the repo and applied by ArgoCD with no out-of-band secret distribution.

Prerequisite: Sealed Secrets controller installed in the cluster (`bitnami-labs/sealed-secrets`). On OpenShift you can install it via OperatorHub. `kubeseal` on your laptop.

```
# 1. Write a Secret manifest locally (DO NOT commit this file).
cat > /tmp/neio-leasingops-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: neio-leasingops-secrets
  namespace: leasingops
type: Opaque
stringData:
  POSTGRES_USER: leasingops
  POSTGRES_PASSWORD: <DB_PASSWORD>
  REDIS_PASSWORD: <REDIS_PASSWORD>
  JWT_SECRET_KEY: $(openssl rand -hex 32)
  ANTHROPIC_API_KEY: ""
EOF

# 2. Seal it against your cluster's public key.
kubeseal --format yaml -f /tmp/neio-leasingops-secrets.yaml > sealed-secret.yaml

# 3. Wipe the plaintext file. The sealed-secret.yaml is safe to commit.
shred -u /tmp/neio-leasingops-secrets.yaml

# 4. Apply (or commit to git and let ArgoCD apply).
oc apply -f sealed-secret.yaml
```

The Sealed Secrets controller decrypts the `SealedSecret` and creates the `Secret` that the chart's deployments mount. The chart itself doesn't need to know whether the secret arrived imperatively or via SealedSecret; it just looks up `neio-leasingops-secrets` by name. The example `examples/sealed-secret.example.yaml` in this repo shows the resulting manifest shape.

A few notes on the keys regardless of path:

- `POSTGRES_USER` and `POSTGRES_PASSWORD` are the credentials the API and worker use to connect to Postgres. If you are using an external database, make sure the database `leasingops` already exists and the user can connect to it.
- `REDIS_PASSWORD` is optional. Omit it if your Redis is unauthenticated.
- `JWT_SECRET_KEY` must be present. `openssl rand -hex 32` generates a strong one.
- `ANTHROPIC_API_KEY` is required by the schema but unused when LlamaStack is the active provider. Leave it empty unless you want a Claude fallback path.

If your Postgres is in-cluster via the Bitnami subchart, the host is set automatically. If it is external, set `database.external.host` in values (see section 7).

## 6. Deploy PostgreSQL and Redis

The chart ships with Bitnami subcharts for Postgres / Redis / MinIO, but on OpenShift restricted-v2 SCC they fight you for UID, fsGroup, and image-user reasons. The simple, reliable path is to deploy standalone Postgres and Redis with manifests that match the Service names the chart's ConfigMap defaults expect. Save the following as `leasingops-data-services.yaml` and apply it. It reuses the credentials from `neio-leasingops-secrets` so everything stays aligned.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: neio-leasingops-postgresql
  namespace: leasingops
spec:
  selector: { app: postgresql }
  ports:
    - { name: pg, port: 5432, targetPort: 5432 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: leasingops
spec:
  replicas: 1
  selector: { matchLabels: { app: postgresql } }
  template:
    metadata: { labels: { app: postgresql } }
    spec:
      containers:
        - name: postgres
          image: docker.io/library/postgres:15-alpine
          ports: [{ containerPort: 5432 }]
          env:
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: neio-leasingops-secrets, key: POSTGRES_USER } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: neio-leasingops-secrets, key: POSTGRES_PASSWORD } }
            - name: POSTGRES_DB
              value: leasingops
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "leasingops", "-d", "leasingops"] }
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
      volumes: [{ name: data, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata:
  name: leasingops-redis
  namespace: leasingops
spec:
  selector: { app: redis }
  ports: [{ name: redis, port: 6379, targetPort: 6379 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: leasingops
spec:
  replicas: 1
  selector: { matchLabels: { app: redis } }
  template:
    metadata: { labels: { app: redis } }
    spec:
      containers:
        - name: redis
          image: docker.io/library/redis:7-alpine
          ports: [{ containerPort: 6379 }]
          command: ["sh", "-c"]
          args: ['exec redis-server --requirepass "$REDIS_PASSWORD" --save "" --appendonly no']
          env:
            - name: REDIS_PASSWORD
              valueFrom: { secretKeyRef: { name: neio-leasingops-secrets, key: REDIS_PASSWORD } }
          readinessProbe:
            exec: { command: ["sh", "-c", 'redis-cli -a "$REDIS_PASSWORD" ping'] }
            initialDelaySeconds: 5
            periodSeconds: 5
```

```
oc apply -f leasingops-data-services.yaml
oc rollout status deploy/postgresql -n leasingops --timeout=180s
oc rollout status deploy/redis -n leasingops --timeout=120s
```

The Redis Service is named `leasingops-redis`, not plain `redis`. Kubernetes auto-injects per-Service env vars (`REDIS_PORT=tcp://...`) for every Service in the namespace, and naming the Service `redis` collides with the `$(REDIS_PORT)` substitution the chart uses to build `REDIS_URL`. The worker then dies with `Port could not be cast to integer value as 'tcp:'`. Using the prefixed name avoids the clash.

For Postgres, the Service name `neio-leasingops-postgresql` matches the chart's default DB host fallback, so no extra wiring is needed when the chart install runs in step 7.

## 7. Install the chart

The chart bundles PostgreSQL, Redis, and MinIO as subchart dependencies (see `Chart.yaml`). Pull them into `charts/` once before the first install:

```
git clone https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo.git
cd Agentic-Lease-Management-and-Reconciliation-with-Codvo

helm dependency build ./leasingops/helm
```

The chart creates its own ServiceAccount (`neio-leasingops`) and a RoleBinding that grants it the `anyuid` SCC, so the application images' built-in `appuser` (uid 1000) is accepted on restricted-v2 clusters. After install, a post-install Hook Job (`*-register-model`) runs inside the cluster and POSTs the Granite model to LlamaStack's `/v1/models`. None of this needs manual `oc create` / `oc adm policy` / `curl POST` commands; the chart and its hooks handle it on every install or upgrade.

Two cluster-specific values you still need to set are the Route hostnames. Save the following as `leasingops-overrides.yaml` next to the chart, replacing the placeholder cluster apps domain with your own:

```yaml
api:
  route:
    host: api-leasingops.apps.<your-cluster-apps-domain>
app:
  route:
    host: leasingops.apps.<your-cluster-apps-domain>
cache:
  # Match the Service name created in step 6.
  host: leasingops-redis
```

Then install:

```
helm install neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  --set 'imagePullSecrets[0].name=acr-pull-secret' \
  --set api.image.repository=rhleasingopsacr.azurecr.io/leasingops-api \
  --set api.image.tag=20260331.01.0003 \
  --set app.image.repository=rhleasingopsacr.azurecr.io/leasingops-app \
  --set app.image.tag=20260331.01.0002 \
  --set worker.image.repository=rhleasingopsacr.azurecr.io/leasingops-worker \
  --set worker.image.tag=20260515.01.0001 \
  --set llamastack.url=http://llamastack:8321 \
  --set llamastack.model=remote-llm/ibm-granite/granite-3.3-2b-instruct \
  --set llamastack.maxTokens=2048 \
  --set database.internal.enabled=false \
  --set cache.internal.enabled=false \
  --set storage.internal.enabled=false \
  -f leasingops/helm/values-openshift.yaml \
  -f leasingops-overrides.yaml
```

Quote `'imagePullSecrets[0].name=acr-pull-secret'` so zsh doesn't glob the `[0]`. The pull secret value must be set at the top-level `imagePullSecrets`, not `global.imagePullSecrets`; the chart only reads the top-level path.

The post-install model-registration Job is named `<release>-register-model` and is auto-deleted by Helm when it succeeds. If it fails, check its logs:

```
oc logs -n leasingops job/neio-leasingops-register-model
```

You can opt out of the auto-registration with `--set llamastack.registerModel=false` if you have your own bootstrap pipeline doing the same POST.

The image tags above are the ones validated in the Red Hat partner lab. Newer tags may exist; ask before changing them.

`llamastack.maxTokens` is capped at 2048 because Granite 3.3 2B has an 8192-token context and the agent prompts already consume around 4000 to 5000 tokens. Going higher causes context overflow errors.

## 8. Verify everything is up

```
oc get pods -n leasingops
```

You should see pods similar to these, all `Running`:

```
granite-3-3-2b-instruct-predictor-xxxx        Running   (on the GPU node)
llamastack-xxxx                                Running
neio-leasingops-api-xxxx                       Running   (1 replica; uploads PVC is RWO)
neio-leasingops-app-xxxx                       Running   (1 replica)
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

## 9. Log in and upload documents

Open the frontend URL in a browser and log in with the demo credentials:

```
Email:    demo@leasingops.ai
Password: EVFbYx@RPt5NnpEZ
```

Upload one of the sample PDFs from `examples/sample-contracts/` and watch it progress through the pipeline. Results appear in the document detail view as each agent completes.

The repository ships 45 real-looking lease documents across ten document types (lease agreements, delivery condition reports, MRCs, return condition reports, amendments, letters of intent, insurance certificates, technical acceptance reports, default notices, supplemental rent statements). You can upload a single document to smoke-test or the full set to load-test.

On CPU each agent takes about 40 seconds per document. A full run of 45 documents across ten agents is around 4.5 hours. On GPU (g5.4xlarge or similar) the same run completes in around 30 to 60 minutes.

## Smoke test with `helm test`

The chart ships a test Pod that exercises the critical path (health check, login, upload, pipeline progress) and exits 0 only if all four pass. Run it any time after install:

```
helm test neio-leasingops -n leasingops --timeout 3m
```

The test takes ~10 seconds and is safe to re-run. It uploads a tiny synthetic document, asserts the worker picks it up, and confirms the pipeline moves past the `upload` stage. The pod is named `<release>-test-api-smoke` and stays in the namespace after the run so you can inspect logs.

Opt out with `--set tests.enabled=false`.

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

## Real-cluster gotchas

These came out of a live deploy on a fresh OpenShift 4.21 partner lab cluster. Each one is the kind of thing where the chart looks like it installed but nothing actually serves traffic, so they're worth knowing about up front.

| What | Effect | Fix in this README |
|---|---|---|
| Chart's `containerSecurityContext` in `values-openshift.yaml` doesn't match the field name `securityContext` the deployment templates read | Security context silently dropped, PodSecurity admission rejects pods, Helm reports "deployed" with no workload | Fixed in chart (`values-openshift.yaml` renamed). |
| Chart hard-codes `runAsUser: 1000` in pod security context | Restricted-v2 SCC rejects (UID must be in namespace range, e.g. 1000790000+) | Override file nulls out runAsUser/runAsGroup; SA gets `anyuid` SCC so the image's `appuser` (uid 1000) is allowed. |
| Container `seccompProfile: RuntimeDefault` is converted by an admission webhook into a deprecated annotation that the SCC forbids | Pod creation rejected | Override file sets `securityContext.seccompProfile: null`. |
| vLLM Service port is `80`, not `8080` | Older docs say 8080 and produce 404s | Use `http://granite-3-3-2b-instruct-vllm:80/v1`. |
| LlamaStack `remote::vllm` provider expects `base_url` to end in `/v1` | Without it, every chat completion returns `404 Not Found` from upstream | Append `/v1` on the install URL. |
| LlamaStack doesn't auto-register models from the configured vLLM URL | Calling chat completions returns "Model not found" | Chart now ships a post-install Helm Job (`<release>-register-model`) that POSTs to `/v1/models` once LlamaStack is healthy. Auto-deletes on success. Opt out with `--set llamastack.registerModel=false`. |
| Chart's `llama-stack` install fails on a missing pgvector PVC by default | `helm install` fails | `--set pgvector.enabled=false`. |
| Naming the Redis Service `redis` exactly collides with Kubernetes auto-injected service env vars (`REDIS_PORT=tcp://...`) | Worker constructs a malformed `REDIS_URL` and dies | Name the Service `leasingops-redis`; set `cache.host=leasingops-redis` in the override file. |
| Chart references SA `neio-leasingops` but did not create it | ReplicaSet stuck on `serviceaccount not found` | Chart now ships a `ServiceAccount` template (gated on `security.serviceAccount.create=true`, which is the default). No manual `oc create sa` needed. |
| Pull secret must be set at top-level `imagePullSecrets`, not `global.imagePullSecrets` | API and worker pods stuck in `ImagePullBackOff` | `--set 'imagePullSecrets[0].name=acr-pull-secret'` (note the top-level key, and quote it so zsh doesn't glob `[0]`). |
| App probe path defaults to `/api/health`, which the Next.js frontend doesn't serve | Container is SIGTERMed every minute → `CrashLoopBackOff` | Override file sets `app.livenessProbe.path: /` and `app.readinessProbe.path: /`. |
| Uploads PVC is `ReadWriteOnce` | Second API/app replica stuck `ContainerCreating` when scheduled to a different node | Override file sets `api.replicas: 1` and `app.replicas: 1`. |
| Chart template defined URL env vars BEFORE the source vars they reference | Kubernetes `$(VAR)` substitution only sees vars defined earlier; URLs ended up containing literal `$(POSTGRES_PORT)` | Fixed in chart. URL env vars now come AFTER `POSTGRES_*` / `REDIS_*` source vars in `templates/{api,worker}/deployment.yaml`. |

## Moving to GPU

To switch the same deployment from CPU to GPU inference, upgrade the LLM chart:

```
helm upgrade llm-inference rh-ai-quickstart/llm-service \
  --version 0.5.9 \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-2b-instruct.enabled=true" \
  --set "models.granite-3-3-2b-instruct.id=ibm-granite/granite-3.3-2b-instruct" \
  --set "models.granite-3-3-2b-instruct.device=gpu"
```

For better output quality, switch to the 8B model. Same license, needs a GPU with around 20 GB of memory:

```
helm upgrade llm-inference rh-ai-quickstart/llm-service \
  --version 0.5.9 \
  --namespace leasingops \
  --set device=gpu \
  --set "models.granite-3-3-8b-instruct.enabled=true" \
  --set "models.granite-3-3-8b-instruct.id=ibm-granite/granite-3.3-8b-instruct"

oc set env deployment/neio-leasingops-worker \
  LLAMASTACK_MODEL=remote-llm/ibm-granite/granite-3.3-8b-instruct \
  -n leasingops
```

## Troubleshooting

`helm install` fails with `missing in charts/ directory: postgresql, redis, minio`: you skipped `helm dependency build`. Run `helm dependency build ./leasingops/helm` once, then retry the install.

`helm install llamastack` fails on a missing PVC for pgvector: you forgot `--set pgvector.enabled=false` on the LlamaStack install in step 3. The application chart does not use the pgvector that LlamaStack tries to bring up by default.

PodSecurity admission warnings on `api` or `worker` (`allowPrivilegeEscalation != false`, `runAsNonRoot != true`, `seccompProfile not set`) and pods never come up: the security context isn't being applied. Confirm `values-openshift.yaml` uses `securityContext:` (not `containerSecurityContext:`) under `app`, `api`, and `worker`. The deployment template reads `.Values.{api,worker,app}.securityContext`, so the wrong field name is silently dropped.

Worker pod in `CrashLoopBackOff`: the `neio-leasingops-secrets` secret is missing or missing a required key. Re-run step 5 and restart the worker (`oc rollout restart deploy/neio-leasingops-worker -n leasingops`).

`NOAUTH Authentication required` from Redis: the password is not being included in the connection URL. Verify the `REDIS_PASSWORD` key exists in the secret, or omit the value entirely if your Redis has no password.

404 on LLM calls: `LLAMASTACK_URL` is wrong. It should be exactly `http://llamastack:8321` with no trailing path. The chart builds the `/v1/chat/completions` suffix internally.

"Model not found" from LlamaStack: the model ID is missing the `remote-llm/` prefix. LlamaStack registers the model with that prefix automatically (see step 3). The chart default is already correct; only override it if you are using a different model.

`max_tokens` or context-length errors: reduce `llamastack.maxTokens`. For Granite 3.3 2B, 2048 is the ceiling.

Documents stuck mid-pipeline (e.g. `term_extraction` never starts after `contract_intake` completes): you are on a worker image older than `20260515.01.0001`. The earlier worker swallowed Langfuse trace exceptions silently and wedged its poll loop after the first agent. Redeploy with `worker.image.tag=20260515.01.0001` or later. The newer image also emits a `worker_poll_heartbeat` log every 10 poll cycles and an `llm_call_done seconds=X` line on every Granite call, so future stalls are observable in `oc logs deploy/neio-leasingops-worker`.

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

## GitOps with ArgoCD / Red Hat Demo Platform

The chart is GitOps-friendly. The post-install Helm Job registers the Granite model with LlamaStack, the ServiceAccount and `anyuid` RoleBinding are templated, and secrets are expected to arrive as `SealedSecret` resources rather than via `oc create secret`. Together that means a single ArgoCD `Application` can drive the install.

An example manifest is in `examples/argocd-application.yaml`. It points at the chart in this repo at `main`, sets the partner-lab-validated image tags, and disables the chart's Bitnami subcharts because Postgres and Redis come from separate manifests. To use it:

```
# 1. Edit the two route hosts in the parameters block to match your cluster's apps domain.
# 2. Apply (or commit to your GitOps repo and let ArgoCD pick it up).
oc apply -f examples/argocd-application.yaml
```

This Application is one node in a larger dependency graph. Before it converges you also need the vLLM and LlamaStack charts installed (separate Applications using `rh-ai-quickstart/llm-service` and `rh-ai-quickstart/llama-stack`), the standalone Postgres + Redis manifests, the ACR pull secret, and the `neio-leasingops-secrets` SealedSecret. Most GitOps repos express that with an "App of Apps" pattern.

For RHDP specifically, RHDP injects `llm.url`, `llm.apiToken`, and `llm.model` at provisioning time. When those are set you don't need the `llamastack.*` parameters above; the chart will use the RSDP values and wire them through to the worker as `LLM_URL`, `LLM_API_TOKEN`, and `LLM_MODEL`.

## Where to get help

For access tokens, image tag refreshes, or deployment questions contact `bala@codvo.ai` or `indranil@codvo.ai`.

Repository: https://github.com/rh-ai-quickstart/Agentic-Lease-Management-and-Reconciliation-with-Codvo

## License

Helm chart and deployment configuration: Apache 2.0 (see `LICENSE`). Application images are proprietary and require a registry pull token from Codvo.
