# NeIO LeasingOps - Security Model

This document describes the security mechanisms the quickstart Helm chart actually
implements, and points to where production hardening goes beyond the quickstart.

> Scope note: this is a quickstart, not a hardened production deployment. The chart
> ships application authentication (JWT) with a demo login, OpenShift-managed TLS on
> the routes, credentials in a Kubernetes Secret, a dedicated ServiceAccount, and an
> SCC RoleBinding so the images run non-root. OIDC/IdP integration, encryption at
> rest, NetworkPolicies, and audit/SIEM pipelines are production concerns you add
> yourself. Sections below cover only what the chart wires up; for everything else
> see [Production hardening](#production-hardening).

## Contents

- [What the chart implements](#what-the-chart-implements)
- [Application authentication](#application-authentication)
- [Secret management](#secret-management)
- [Registry pull secret](#registry-pull-secret)
- [ServiceAccount and SCC](#serviceaccount-and-scc)
- [TLS in transit](#tls-in-transit)
- [Network policies (recommended, not shipped)](#network-policies-recommended-not-shipped)
- [Production hardening](#production-hardening)

---

## What the chart implements

| Mechanism | Where | Default |
|-----------|-------|---------|
| Application Secret (DB, cache, JWT, demo login) | `templates/secrets/secrets.yaml` | created, auto-generated |
| ACR image pull secret | `templates/pull-secret.yaml` | created when `imageCredentials.create=true` |
| ServiceAccount | `templates/serviceaccount.yaml` | created when `serviceAccount.create=true` |
| `anyuid` SCC RoleBinding | `templates/scc-rolebinding.yaml` | created when `openshift.grantAnyuid=true` |
| TLS edge termination on routes | `templates/app/route.yaml`, `templates/api/route.yaml` | enabled, HTTP redirected to HTTPS |
| Non-root pods (uid 1000) | deployment security contexts | enforced |

Anything not in this table (OIDC, RBAC roles, encryption-at-rest, audit pipelines)
is not wired by the chart, regardless of keys that may linger in `values.yaml`. The
templates under `leasingops/helm/templates/` are the source of truth.

---

## Application authentication

The application authenticates users with JWT. The chart generates `JWT_SECRET_KEY`
(64 chars) and `DEMO_PASSWORD` (20 chars) into the application Secret on first
install. The API consumes both from the Secret; it refuses to start if
`DEMO_PASSWORD` is unset.

Retrieve the demo-login password after install:

```bash
oc get secret neio-leasingops-secrets -n leasingops \
  -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d
```

The bundled login is `demo@leasingops.ai` with that password. There is no OIDC/IdP
integration in the chart; front the route with an identity provider for production
(see [Production hardening](#production-hardening)).

---

## Secret management

The chart creates `neio-leasingops-secrets`, a regular Kubernetes Secret, when
`secrets.create=true` (the default).

- Passwords are auto-generated on first install and **preserved across upgrades**.
  The template carries `helm.sh/resource-policy: keep` and looks up the existing
  Secret, so values stay stable and no manual secret-creation step is needed.
- Override any value with `secrets.data.<KEY>` (for example
  `--set secrets.data.ANTHROPIC_API_KEY=...`).

Keys:

| Key | Generated | Purpose |
|-----|-----------|---------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | yes | PostgreSQL credentials |
| `REDIS_PASSWORD` | yes | Redis password |
| `JWT_SECRET_KEY` | yes | JWT signing key |
| `DEMO_PASSWORD` | yes | Demo-login password |
| `ANTHROPIC_API_KEY` | empty unless set | optional Claude fallback |
| `OPENAI_API_KEY`, `VOYAGE_API_KEY`, `QDRANT_API_KEY`, `JWT_REFRESH_SECRET_KEY`, `LANGFUSE_*` | only if provided | optional integrations |

### Sealed Secrets

For GitOps where the Secret is committed, set `secrets.sealed=true` and supply
pre-encrypted values under `secrets.sealedData.*`. The template then renders a
Bitnami `SealedSecret` instead of a plain Secret. Encrypt values with `kubeseal`:

```bash
kubeseal --format yaml --cert sealed-secrets-cert.pem < secret.yaml > sealed-secret.yaml
```

---

## Registry pull secret

The application images live in a private registry (ACR). Set
`imageCredentials.create=true` and pass the credentials so the chart renders a
`kubernetes.io/dockerconfigjson` pull secret in one `helm install`:

```bash
helm install ... \
  --set imageCredentials.username=<acr-user> \
  --set imageCredentials.password=<acr-token>
```

`imageCredentials.registry` defaults to `rhleasingopsacr.azurecr.io` and
`imageCredentials.name` to `acr-pull-secret`. A second, optional generic pull
secret is available via `secrets.imagePullSecret.create` with a pre-built
`dockerConfigJson`.

---

## ServiceAccount and SCC

The application images run as `USER appuser` (uid 1000). On clusters where the
namespace default is the OpenShift `restricted-v2` SCC, that fixed UID is rejected.

- `templates/serviceaccount.yaml` creates the ServiceAccount the api, worker, and
  app deployments reference (`serviceAccount.create=true`).
- `templates/scc-rolebinding.yaml` binds that ServiceAccount to the `anyuid` SCC via
  a namespaced RoleBinding (`openshift.grantAnyuid=true`, the default), so pods run
  as uid 1000 without a cluster-admin running `oc adm policy add-scc-to-user` by
  hand. On non-OpenShift clusters the template renders nothing.

Set `openshift.grantAnyuid=false` if you bind the SCC out of band.

---

## TLS in transit

The app and api routes terminate TLS at the OpenShift edge:

```yaml
tls:
  termination: edge
  insecureEdgeTerminationPolicy: Redirect   # HTTP redirected to HTTPS
```

By default the routes use the cluster's wildcard serving certificate. To supply your
own, set `app.route.tls.certificate`, `app.route.tls.key`, and optionally
`app.route.tls.caCertificate` (same keys under `api.route.tls`).

---

## Network policies (recommended, not shipped)

The chart does not ship NetworkPolicy resources, and there is no value to toggle
them. The manifests below are a recommended starting point you apply yourself with
`oc apply`. The selectors match the labels the chart sets
(`app.kubernetes.io/component`). A default-deny policy breaks traffic until the allow
rules are in place, so review them against your namespace first.

```yaml
# Deny all traffic by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: leasingops
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Allow ingress from the OpenShift router to the frontend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-router
  namespace: leasingops
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: app
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - { port: 3000, protocol: TCP }
---
# Allow api and worker to reach the in-cluster PostgreSQL and Redis
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-data
  namespace: leasingops
spec:
  podSelector:
    matchExpressions:
      - { key: app.kubernetes.io/component, operator: In, values: [postgresql, redis] }
  ingress:
    - from:
        - podSelector: { matchLabels: { app.kubernetes.io/component: api } }
        - podSelector: { matchLabels: { app.kubernetes.io/component: worker } }
      ports:
        - { port: 5432, protocol: TCP }
        - { port: 6379, protocol: TCP }
```

---

## Production hardening

The quickstart deliberately stops at a single-namespace, demo-login deployment. For
a production posture, layer on:

- An identity provider in front of the routes (OpenShift OAuth, Keycloak/Red Hat
  SSO, or any OIDC IdP) instead of the demo login.
- Encryption at rest for PostgreSQL and the uploads PVC, via your storage class or
  cluster KMS.
- NetworkPolicies (the section above is a starting point).
- External secret management (HashiCorp Vault or the External Secrets Operator)
  feeding `neio-leasingops-secrets`.
- Centralized audit logging and SIEM forwarding from the application's stdout logs.
- Compliance mapping (SOC 2, ISO 27001, GDPR) for your environment.

Codvo.ai maintains the production hardening guidance for these topics. For a
hardened deployment of NeIO LeasingOps, contact Codvo.ai (support@codvo.ai) for the
production reference architecture; report security issues to security@codvo.ai.

---

## Related docs

- [Installation Guide](./INSTALLATION.md)
- [Configuration Reference](./CONFIGURATION.md)
- [Troubleshooting](./TROUBLESHOOTING.md)
- [Air-Gapped Deployment](./AIRGAPPED.md)
