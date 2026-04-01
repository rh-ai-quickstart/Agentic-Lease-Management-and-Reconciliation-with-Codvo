# Upgrade Guide

This document describes how to upgrade NeIO LeasingOps to a new chart version.

---

## Before You Upgrade

1. **Read the release notes** for the target version — check the [VERSIONING.md](../VERSIONING.md) and GitHub Releases page for breaking changes.
2. **Back up your database** before any major version upgrade (X.Y → X+1.0):

   ```bash
   oc exec -n leasingops deploy/leasingops-api -- \
     pg_dump $DATABASE_URL > leasingops-backup-$(date +%Y%m%d).sql
   ```

3. **Check your custom values** — compare your current `values.yaml` overrides against the new chart's default `values.yaml` for any renamed or removed keys.

---

## Standard Upgrade (Patch / Minor)

For patch releases (1.0.x) and minor releases (1.x.0) with no breaking changes:

```bash
# Pull latest chart from git first
git -C Agentic-Lease-Management-and-Reconciliation-with-Codvo pull

# Preview changes (dry run)
helm upgrade leasingops ./leasingops/helm \
  --namespace leasingops \
  --dry-run \
  -f your-values.yaml

# Apply the upgrade
helm upgrade leasingops ./leasingops/helm \
  --namespace leasingops \
  -f your-values.yaml
```

The upgrade performs a rolling update — existing pods continue serving traffic while new pods are started.

---

## Major Version Upgrade

Major upgrades (X.Y → X+1.0) may include database schema migrations. The API pod runs `alembic upgrade head` automatically on startup when `worker.runMigrations: true` (default).

```bash
# 1. Scale down workers to avoid mid-migration job processing
oc scale deploy/leasingops-worker --replicas=0 -n leasingops

# 2. Run the upgrade
helm upgrade leasingops ./leasingops/helm \
  --namespace leasingops \
  --set worker.runMigrations=true \
  -f your-values.yaml

# 3. Wait for the API pod to complete migrations
oc rollout status deploy/leasingops-api -n leasingops

# 4. Scale workers back up
oc scale deploy/leasingops-worker --replicas=2 -n leasingops
```

---

## RSDP Deployments

If deployed via the Red Hat Solution Deployment Platform, upgrades are managed through the RSDP catalog. Update the solution version in your RSDP workspace and re-deploy — RSDP handles rolling upgrades and re-injects the LLM credentials automatically.

---

## Rollback

If an upgrade fails, roll back to the previous release:

```bash
# List release history
helm history leasingops -n leasingops

# Roll back to the previous revision
helm rollback leasingops -n leasingops

# Roll back to a specific revision
helm rollback leasingops 3 -n leasingops
```

---

## Verifying the Upgrade

```bash
# Check all pods are running
oc get pods -n leasingops

# Confirm the new chart version
helm list -n leasingops

# Smoke test the API
curl -s https://$(oc get route leasingops-api -n leasingops \
  -o jsonpath='{.spec.host}')/health | jq .
```

---

## Related Documentation

- [Installation Guide](INSTALLATION.md) — fresh installation
- [Configuration Reference](CONFIGURATION.md) — values reference
- [Troubleshooting](TROUBLESHOOTING.md) — common upgrade issues
