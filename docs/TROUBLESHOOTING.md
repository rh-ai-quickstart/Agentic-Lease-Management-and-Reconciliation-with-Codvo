# NeIO LeasingOps - Troubleshooting Guide

This guide covers common issues and their solutions when deploying and operating NeIO LeasingOps.

## Table of Contents

- [Diagnostic Commands](#diagnostic-commands)
- [Pod Startup Issues](#pod-startup-issues)
- [Database Connectivity](#database-connectivity)
- [Pull Secret Problems](#pull-secret-problems)
- [Token Validation Errors](#token-validation-errors)
- [AI Provider Issues](#ai-provider-issues)
- [Performance Issues](#performance-issues)
- [Logging and Debugging](#logging-and-debugging)
- [Common Error Messages](#common-error-messages)

---

## Diagnostic Commands

### Quick Health Check

```bash
# Check all pods in namespace
oc get pods -n leasingops -o wide

# Check events for issues
oc get events -n leasingops --sort-by='.lastTimestamp' | tail -20

# Check Helm release status
helm status leasingops -n leasingops

# API health check
curl -s https://$(oc get route leasingops-app -n leasingops -o jsonpath='{.spec.host}')/api/health | jq
```

### Detailed Pod Diagnostics

```bash
# Describe a specific pod
oc describe pod <pod-name> -n leasingops

# Check pod logs
oc logs <pod-name> -n leasingops --tail=100

# Check previous container logs (after crash)
oc logs <pod-name> -n leasingops --previous

# Follow logs in real-time
oc logs -f <pod-name> -n leasingops

# Check all containers in a pod
oc logs <pod-name> -n leasingops --all-containers
```

### Resource Usage

```bash
# Check node resources
oc adm top nodes

# Check pod resource usage
oc adm top pods -n leasingops

# Check PVC usage
oc get pvc -n leasingops
oc exec deploy/neio-leasingops-postgresql -n leasingops -- df -h /var/lib/postgresql/data
```

---

## Pod Startup Issues

### Issue: Pods Stuck in Pending

**Symptoms:**
```
NAME                              READY   STATUS    RESTARTS   AGE
neio-leasingops-api-xxx                0/1     Pending   0          5m
```

**Causes and Solutions:**

1. **Insufficient Resources**
   ```bash
   # Check events for scheduling failures
   oc describe pod <pod-name> -n leasingops | grep -A 10 Events

   # If "Insufficient cpu" or "Insufficient memory":
   # Option 1: Add more nodes
   # Option 2: Reduce resource requests in values.yaml
   ```

2. **No Matching Nodes (nodeSelector/tolerations)**
   ```bash
   # Check node labels
   oc get nodes --show-labels

   # Verify nodeSelector matches
   oc get pod <pod-name> -n leasingops -o yaml | grep -A 5 nodeSelector
   ```

3. **PVC Not Bound**
   ```bash
   # Check PVC status
   oc get pvc -n leasingops

   # If Pending, check storage class
   oc describe pvc <pvc-name> -n leasingops

   # Verify storage class exists
   oc get storageclass
   ```

### Issue: Pods in CrashLoopBackOff

**Symptoms:**
```
NAME                              READY   STATUS             RESTARTS   AGE
neio-leasingops-api-xxx                0/1     CrashLoopBackOff   5          10m
```

**Diagnostic Steps:**

```bash
# Check logs from crashed container
oc logs <pod-name> -n leasingops --previous

# Check container exit code
oc get pod <pod-name> -n leasingops -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

**Common Causes:**

1. **Exit Code 1 - Application Error**
   - Check application logs for stack traces
   - Verify environment variables are set correctly
   - Check database connectivity

2. **Exit Code 137 - OOM Killed**
   ```bash
   # Check if OOMKilled
   oc get pod <pod-name> -n leasingops -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'

   # Solution: Increase memory limits
   ```

3. **Exit Code 1 - Missing Secrets**
   ```bash
   # Verify secrets exist
   oc get secrets -n leasingops

   # Check if secret keys match
   oc get secret ai-credentials -n leasingops -o jsonpath='{.data}' | jq
   ```

### Issue: Pods Stuck in Init

**Symptoms:**
```
NAME                              READY   STATUS     RESTARTS   AGE
neio-leasingops-api-xxx                0/1     Init:0/1   0          5m
```

**Solution:**

```bash
# Check init container logs
oc logs <pod-name> -n leasingops -c init-wait-for-db

# Common fix: Wait for dependencies
oc wait --for=condition=ready pod -l app=postgresql -n leasingops --timeout=120s
```

---

## Database Connectivity

### Issue: Cannot Connect to PostgreSQL

**Symptoms:**
- API pods failing with "connection refused"
- "FATAL: password authentication failed"
- "FATAL: database does not exist"

**Diagnostic Steps:**

```bash
# Check PostgreSQL pod status
oc get pods -l app.kubernetes.io/name=postgresql -n leasingops

# Test connectivity from API pod
oc exec -it deployment/neio-leasingops-api -n leasingops -- \
  python -c "import psycopg2; print(psycopg2.connect('$DATABASE_URL'))"

# Check PostgreSQL logs
oc logs -l app.kubernetes.io/name=postgresql -n leasingops --tail=50
```

**Solutions:**

1. **Wrong Password**
   ```bash
   # Verify password in secret matches PostgreSQL
   oc get secret db-credentials -n leasingops -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

   # Reset password if needed
   oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
     psql -U postgres -c "ALTER USER leasingops PASSWORD 'new-password';"
   ```

2. **Database Does Not Exist**
   ```bash
   # Create database
   oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
     psql -U postgres -c "CREATE DATABASE leasingops;"
   ```

3. **pgvector Extension Missing**
   ```bash
   # Install pgvector extension
   oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
     psql -U postgres -d leasingops -c "CREATE EXTENSION IF NOT EXISTS vector;"
   ```

4. **Connection Pool Exhausted**
   ```bash
   # Check active connections
   oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
     psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

   # Increase max_connections in values.yaml
   ```

### Issue: Redis Connection Failures

**Symptoms:**
- "Connection refused" to Redis
- Worker jobs not processing
- Session issues

**Solutions:**

```bash
# Check Redis pod
oc get pods -l app.kubernetes.io/name=redis -n leasingops

# Test Redis connectivity
oc exec -it deployment/neio-leasingops-api -n leasingops -- \
  python -c "import redis; r = redis.from_url('$REDIS_URL'); print(r.ping())"

# Check Redis logs
oc logs -l app.kubernetes.io/name=redis -n leasingops

# Verify Redis password
oc get secret redis-credentials -n leasingops -o jsonpath='{.data.redis-password}' | base64 -d
```

---

## Pull Secret Problems

### Issue: ImagePullBackOff

**Symptoms:**
```
NAME                              READY   STATUS             RESTARTS   AGE
neio-leasingops-api-xxx                0/1     ImagePullBackOff   0          5m
```

**Diagnostic Steps:**

```bash
# Get detailed error
oc describe pod <pod-name> -n leasingops | grep -A 5 "Failed to pull"

# Check pull secret exists
oc get secret acr-secret -n leasingops

# Verify pull secret is linked to service account
oc get serviceaccount default -n leasingops -o yaml | grep imagePullSecrets
```

**Solutions:**

1. **Pull Secret Does Not Exist**
   ```bash
   # Create pull secret (contact bala@codvo.ai for credentials)
   oc create secret docker-registry acr-secret \
     --docker-server=rhleasingopsacr.azurecr.io \
     --docker-username=<acr-username> \
     --docker-password=<acr-password> \
     -n leasingops
   ```

2. **Pull Secret Not Linked**
   ```bash
   # Link secret to service account
   oc secrets link default acr-secret --for=pull -n leasingops

   # Or add to deployment
   oc patch deployment neio-leasingops-api -n leasingops \
     -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"acr-secret"}]}}}}'
   ```

3. **Invalid Credentials**
   ```bash
   # Test pull secret manually
   oc run test-pull --image=rhleasingopsacr.azurecr.io/leasingops-api:20260615.01.0001 \
     --restart=Never --rm -it \
     --overrides='{"spec":{"imagePullSecrets":[{"name":"acr-secret"}]}}' \
     -n leasingops -- echo "Pull successful"
   ```

4. **Registry Unreachable**
   ```bash
   # Test network connectivity
   oc run network-test --image=curlimages/curl --rm -it --restart=Never -n leasingops -- \
     curl -s -o /dev/null -w "%{http_code}" https://rhleasingopsacr.azurecr.io/v2/
   ```

---

## Token and secret errors

There is no separate application "license token" in this deployment. The only credentials are the image pull secret (`acr-pull-secret`) and the application secret (`neio-leasingops-secrets`), both created in README step 3.

### Issue: API or worker won't start, missing secret key

**Symptoms:**
- API or worker in `CrashLoopBackOff`
- Logs mention a missing environment variable such as `DEMO_PASSWORD`, `JWT_SECRET_KEY`, or `POSTGRES_PASSWORD`

The API refuses to start if a required key is absent from `neio-leasingops-secrets`. Confirm every key is present:

```bash
oc get secret neio-leasingops-secrets -n leasingops -o jsonpath='{.data}' | tr ',' '\n'
```

Expected keys: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `JWT_SECRET_KEY`, `DEMO_PASSWORD`, `ANTHROPIC_API_KEY`. If one is missing, recreate the secret (README step 3) and restart:

```bash
oc rollout restart deploy/neio-leasingops-api deploy/neio-leasingops-worker -n leasingops
```

### Issue: JWT Authentication Failures

**Symptoms:**
- "401 Unauthorized" responses
- "Invalid token" or "Token expired" errors

Update just the JWT key in place so the other keys are not disturbed, then restart:

```bash
oc patch secret neio-leasingops-secrets -n leasingops \
  --type merge -p "{\"stringData\":{\"JWT_SECRET_KEY\":\"$(openssl rand -hex 32)\"}}"

oc rollout restart deploy/neio-leasingops-api -n leasingops
```

Rotating `JWT_SECRET_KEY` invalidates existing logins, so users will need to log in again.

---

## AI Provider Issues

### Issue: Anthropic API Errors

**Symptoms:**
- "401 Unauthorized" from Anthropic
- "Rate limit exceeded"
- "Model not found"

**Solutions:**

1. **Invalid API Key**
   ```bash
   # Verify API key is set
   oc get secret ai-credentials -n leasingops -o jsonpath='{.data.ANTHROPIC_API_KEY}' | base64 -d | head -c 10

   # Update API key
   oc create secret generic ai-credentials \
     --from-literal=ANTHROPIC_API_KEY='sk-ant-...' \
     --from-literal=VOYAGE_API_KEY='pa-...' \
     -n leasingops \
     --dry-run=client -o yaml | oc apply -f -
   ```

2. **Rate Limiting**
   ```bash
   # Check current rate limit settings
   oc get configmap leasingops-config -n leasingops -o yaml | grep -A 5 rateLimit

   # Reduce concurrent requests in values.yaml
   ai:
     rateLimit:
       requestsPerMinute: 50  # Reduce from 100
   ```

3. **Model Not Available**
   - Verify model name is correct: `claude-sonnet-4-20250514`
   - Check Anthropic status page for outages

### Issue: OpenShift AI Model Serving

**Symptoms:**
- InferenceService not ready
- "Model not found" errors
- GPU scheduling failures

**Solutions:**

```bash
# Check InferenceService status
oc get inferenceservice -n leasingops

# Describe for detailed status
oc describe inferenceservice leasingops-llm -n leasingops

# Check model server logs
oc logs -l serving.kserve.io/inferenceservice=leasingops-llm -n leasingops

# Verify GPU availability
oc describe nodes | grep -A 10 "nvidia.com/gpu"
```

---

## Performance Issues

### Issue: Slow API Response Times

**Symptoms:**
- API latency > 2 seconds
- Timeout errors
- User complaints about performance

**Diagnostic Steps:**

```bash
# Check API metrics
curl -s http://neio-leasingops-api:8001/metrics | grep http_request_duration

# Check database query times
oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
  psql -U postgres -d leasingops -c "SELECT query, mean_time FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"

# Check API pod resources
oc adm top pods -l app.kubernetes.io/component=api -n leasingops
```

**Solutions:**

1. **Increase API Resources**
   ```yaml
   api:
     resources:
       requests:
         cpu: 4
         memory: 8Gi
       limits:
         cpu: 8
         memory: 16Gi
   ```

2. **Add Database Indexes**
   ```bash
   oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
     psql -U postgres -d leasingops -c "
       CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contracts_created
       ON contracts(created_at DESC);
     "
   ```

3. **Increase Connection Pool**
   ```yaml
   api:
     env:
       DB_POOL_SIZE: "30"
       DB_POOL_OVERFLOW: "20"
   ```

### Issue: Worker Queue Backlog

**Symptoms:**
- Jobs not processing
- Queue depth increasing
- Document ingestion delays

**Diagnostic Steps:**

```bash
# Check queue depth
oc exec -it deployment/neio-leasingops-api -n leasingops -- \
  python -c "import redis; r = redis.from_url('$REDIS_URL'); print(r.llen('celery'))"

# Check worker status
oc exec -it deployment/neio-leasingops-worker -n leasingops -- \
  celery -A app.worker inspect active

# Check worker logs for errors
oc logs -l app.kubernetes.io/component=worker -n leasingops --tail=100
```

**Solutions:**

1. **Scale Workers**
   ```bash
   oc scale deployment/neio-leasingops-worker --replicas=5 -n leasingops
   ```

2. **Increase Worker Concurrency**
   ```yaml
   worker:
     concurrency: 8
   ```

3. **Enable Worker Autoscaling**
   ```yaml
   worker:
     autoscaling:
       enabled: true
       minReplicas: 2
       maxReplicas: 10
   ```

### Issue: Memory Pressure

**Symptoms:**
- Pods being OOMKilled
- Slow performance
- Node pressure warnings

**Solutions:**

```bash
# Identify memory-heavy pods
oc adm top pods -n leasingops --sort-by=memory

# Check for memory leaks
oc exec -it <pod-name> -n leasingops -- \
  python -c "import tracemalloc; tracemalloc.start(); # application code"

# Increase limits or add more nodes
```

---

## Logging and Debugging

### Enable Debug Logging

```bash
# Temporarily enable debug logging
oc set env deployment/neio-leasingops-api LOG_LEVEL=DEBUG -n leasingops

# Watch debug logs
oc logs -f deployment/neio-leasingops-api -n leasingops

# Revert to INFO
oc set env deployment/neio-leasingops-api LOG_LEVEL=INFO -n leasingops
```

### Access Application Shell

```bash
# Shell into API pod
oc exec -it deployment/neio-leasingops-api -n leasingops -- /bin/bash

# Run Python debugging
python -c "from app.core.config import settings; print(settings.dict())"
```

### Database Debugging

```bash
# Connect to PostgreSQL
oc exec -it deploy/neio-leasingops-postgresql -n leasingops -- \
  psql -U postgres -d leasingops

# Useful queries
# Check table sizes
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

# Check slow queries
SELECT query, calls, mean_time, total_time
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;
```

### Network Debugging

```bash
# Test internal connectivity
oc run network-debug --image=nicolaka/netshoot --rm -it --restart=Never -n leasingops

# Inside pod:
nslookup neio-leasingops-postgresql
curl -v http://neio-leasingops-api:8001/health
```

---

## Common Error Messages

### "Connection refused to localhost:5432"

**Cause:** Application trying to connect to localhost instead of PostgreSQL service.

**Solution:**
```bash
# Check DATABASE_URL environment variable
oc exec deployment/neio-leasingops-api -n leasingops -- printenv DATABASE_URL

# Should be: postgresql://user:pass@neio-leasingops-postgresql:5432/leasingops
```

### "No such collection: documents"

**Cause:** Qdrant collection not initialized.

**Solution:**
```bash
# Create collection manually
curl -X PUT "http://leasingops-qdrant:6333/collections/documents" \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "size": 1024,
      "distance": "Cosine"
    }
  }'
```

### "SQLSTATE[42P01]: Undefined table"

**Cause:** Database migrations not run.

**Solution:**
```bash
oc exec -it deployment/neio-leasingops-api -n leasingops -- \
  python -m alembic upgrade head
```

### "Rate limit exceeded for model"

**Cause:** Too many API requests to LLM provider.

**Solution:**
- Reduce `ai.rateLimit.requestsPerMinute`
- Enable response caching
- Consider using OpenShift AI for local inference

---

## Getting Help

If you cannot resolve an issue:

1. **Collect Diagnostics**
   ```bash
   ./scripts/collect-diagnostics.sh > diagnostics-$(date +%Y%m%d).tar.gz
   ```

2. **Check Documentation**
   - [Architecture Overview](./ARCHITECTURE.md)
   - [Configuration Reference](./CONFIGURATION.md)

3. **Contact Support**
   - Enterprise Support: support@codvo.ai
   - Include diagnostic bundle and error logs
