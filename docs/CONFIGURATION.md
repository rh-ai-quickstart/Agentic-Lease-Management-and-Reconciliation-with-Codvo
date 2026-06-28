# NeIO LeasingOps - Configuration Reference

This documents the configuration surface that matters for the quickstart: the values you set to install and run the chart.

> Scope note: the chart's `values.yaml` was inherited from a larger platform chart and still carries keys the quickstart templates do not read (object storage, Qdrant/Milvus vector stores, Keycloak/Okta auth, LLMD, LiteLLM, and others). Those keys do nothing in this deployment. The values listed below are the ones the templates actually consume. When in doubt, the templates under `leasingops/helm/templates/` are the source of truth, not the comments in `values.yaml`.

---

## How configuration is supplied

Helm merges values files left to right, last wins. The README installs with:

```bash
helm install neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  -f leasingops/helm/values-openshift.yaml \
  -f leasingops-overrides.yaml \
  --set api.image.tag=... [etc]
```

- `values.yaml` ships chart defaults.
- `values-openshift.yaml` applies the OpenShift specifics (route TLS, security contexts, SCC).
- Your overrides file (or `--set`) supplies the cluster-specific bits: image tags, route hosts, and the image pull secret.

---

## Values you set for a quickstart install

| Value | Purpose | Example |
|-------|---------|---------|
| `global.imagePullSecrets` | List of pull secrets for the private image registry | `[acr-pull-secret]` |
| `api.image.repository` / `api.image.tag` | API image | `rhleasingopsacr.azurecr.io/leasingops-api` / `20260615.01.0001` |
| `app.image.repository` / `app.image.tag` | Frontend image | `.../leasingops-app` / `20260615.01.0001` |
| `worker.image.repository` / `worker.image.tag` | Worker image | `.../leasingops-worker` / `20260615.01.0001` |
| `api.route.host` | API route hostname | `api-leasingops.<cluster-apps-domain>` |
| `app.route.host` | Frontend route hostname | `leasingops.<cluster-apps-domain>` |
| `app.env.apiUrl` | Backend URL the frontend proxy targets. Defaults to the in-cluster API Service, so you rarely set it | `http://neio-leasingops-api:8001` |

---

## Model server (LlamaStack)

The application reaches Granite through LlamaStack. These are the only AI values the templates read for the default path.

| Value | Default | Notes |
|-------|---------|-------|
| `llamastack.url` | `http://llamastack:8321` | In-cluster LlamaStack Service |
| `llamastack.model` | `remote-llm/ibm-granite/granite-3.3-2b-instruct` | Provider-prefixed model id, as LlamaStack stores it |
| `llamastack.maxTokens` | `2048` | Keep within Granite 3.3 2B's 8192-token context |
| `llamastack.registerModel` | `true` | Runs the post-install Job that registers the model with LlamaStack |

To use a larger model, deploy it in step 2 and set `llamastack.model` to its provider-prefixed id.

---

## Database and cache

The chart deploys its own PostgreSQL and Redis by default. Point it at external ones by disabling the in-cluster deployment and supplying a host.

| Value | Default | Notes |
|-------|---------|-------|
| `database.deployInCluster` | `true` | When `false`, the chart deploys no Postgres and uses `database.external.host` |
| `database.external.host` | (unset) | External PostgreSQL host when not deploying in-cluster |
| `cache.deployInCluster` | `true` | When `false`, the chart deploys no Redis and uses `cache.host` |
| `cache.host` | (unset) | External Redis host when not deploying in-cluster |

Credentials for both come from the application secret (`neio-leasingops-secrets`), whether in-cluster or external. For an external database, create the `leasingops` database and user beforehand.

---

## Uploads volume

| Value | Default | Notes |
|-------|---------|-------|
| `uploads.pvcName` | `leasingops-uploads` | Shared PVC mounted by API and worker |
| `uploads.storageClass` | `gp3-csi` | Use a storage class your cluster offers; `gp3-csi` on OpenShift/AWS |
| `uploads.size` | `5Gi` | Increase for large document sets |

---

## Scaling and resources

`api`, `app`, and `worker` each take `replicas` (or `replicaCount`), `resources.requests` / `resources.limits`, and an `autoscaling` block (`enabled`, `minReplicas`, `maxReplicas`, `targetCPUUtilizationPercentage`). Defaults are sized for a demo. The worker is single-replica by default; raise `worker.replicas` to process more documents in parallel.

For CPU-backed local LLM inference, keep the worker single-replica unless you have sized the model server for concurrent requests. The worker also exposes `worker.llmCallTimeoutSeconds`, rendered as `LLM_CALL_TIMEOUT_SECONDS`. The base default is `300`; `values-openshift.yaml` sets `360` because CPU-hosted Granite can take 2-3 minutes for the larger extraction, evidence, and decision prompts. GPU-backed vLLM normally completes much faster, but the higher timeout is harmless and avoids unnecessary retries on slower clusters.

---

## Secrets

The application reads its credentials from the `neio-leasingops-secrets` Secret. The README creates it imperatively with these keys:

| Key | Purpose |
|-----|---------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Database credentials (used by the in-cluster Postgres and the app) |
| `REDIS_PASSWORD` | Redis password |
| `JWT_SECRET_KEY` | Signs application login tokens |
| `DEMO_PASSWORD` | Password for the bundled `demo@leasingops.ai` login |
| `ANTHROPIC_API_KEY` | Optional Claude fallback; may be empty |

For GitOps, the chart can render the Secret from `secrets.data.*` (or `secrets.sealedData.*` for Sealed Secrets) instead of creating it by hand. See Appendix C of the README.

---

## Related Documentation

- [README](../README.md) — install and walkthrough
- [Architecture](./ARCHITECTURE.md) — system design
- [Troubleshooting](./TROUBLESHOOTING.md) — common issues
