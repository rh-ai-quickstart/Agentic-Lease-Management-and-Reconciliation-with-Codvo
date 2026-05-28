# Upgrade Guide

This document describes how to upgrade NeIO LeasingOps to a new chart version.

The release name and resource names below assume you installed with `helm install neio-leasingops ./leasingops/helm`, as in the README. If you used a different release name, substitute it.

---

## Before You Upgrade

1. **Read the release notes** for the target version. Check [VERSIONING.md](../VERSIONING.md) and the GitHub Releases page for breaking changes.
2. **Back up your database** before any major version upgrade (X.Y to X+1.0):

   ```bash
   oc exec -n leasingops deploy/neio-leasingops-api -- \
     pg_dump "$DATABASE_URL" > leasingops-backup-$(date +%Y%m%d).sql
   ```

3. **Check your custom values.** Compare your current overrides against the new chart's default `values.yaml` for any renamed or removed keys.

---

## Standard Upgrade (Patch / Minor)

For patch releases (1.0.x) and minor releases (1.x.0) with no breaking changes:

```bash
# Pull the latest chart from git first
git -C Agentic-Lease-Management-and-Reconciliation-with-Codvo pull

# Preview changes (dry run)
helm upgrade neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  --dry-run \
  -f your-values.yaml

# Apply the upgrade
helm upgrade neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  -f your-values.yaml
```

The upgrade performs a rolling update: existing pods continue serving traffic while new pods start.

---

## Major Version Upgrade

Major upgrades (X.Y to X+1.0) may include database schema migrations. The API pod runs `alembic upgrade head` automatically on startup.

```bash
# 1. Scale workers down to avoid mid-migration job processing
oc scale deploy/neio-leasingops-worker --replicas=0 -n leasingops

# 2. Run the upgrade
helm upgrade neio-leasingops ./leasingops/helm \
  --namespace leasingops \
  -f your-values.yaml

# 3. Wait for the API pod to finish migrations
oc rollout status deploy/neio-leasingops-api -n leasingops

# 4. Scale workers back up
oc scale deploy/neio-leasingops-worker --replicas=1 -n leasingops
```

---

## Rollback

If an upgrade fails, roll back to the previous release:

```bash
# List release history
helm history neio-leasingops -n leasingops

# Roll back to the previous revision
helm rollback neio-leasingops -n leasingops

# Roll back to a specific revision
helm rollback neio-leasingops 3 -n leasingops
```

---

## Verifying the Upgrade

```bash
# Check all pods are running
oc get pods -n leasingops

# Confirm the new chart version
helm list -n leasingops

# Smoke test the API
curl -k "https://$(oc get route neio-leasingops-api -n leasingops \
  -o jsonpath='{.spec.host}')/health"
```

---

## Related Documentation

- [Installation Guide](INSTALLATION.md) — fresh installation
- [Configuration Reference](CONFIGURATION.md) — values reference
- [Troubleshooting](TROUBLESHOOTING.md) — common upgrade issues
