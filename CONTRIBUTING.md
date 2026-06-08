# Contributing

Thanks for your interest in the NeIO LeasingOps quickstart. This repository is the Helm chart, sample contracts, and documentation for deploying the application on Red Hat OpenShift AI. The application source (the frontend, API, and agent worker) is maintained separately by Codvo and shipped as container images; this repository packages and documents the deployment.

## What lives here

- `leasingops/helm/` — the application Helm chart (frontend, API, worker, PostgreSQL, Redis).
- `helm/infra/`, `dependencies/`, `openshift-ai/` — supporting charts and values.
- `examples/` — sample lease contracts and example manifests (ArgoCD, SealedSecret).
- `scripts/` — `teardown.sh` and deployment helpers.
- `docs/` — architecture, configuration, getting started, troubleshooting, and the OpenShift AI integration notes.

## Reporting issues

Open a GitHub issue and include:

- The OpenShift version and how you deployed (the `helm install` command or values you used).
- The relevant pod logs, for example `oc logs deploy/neio-leasingops-worker -n leasingops --tail=100`.

Check [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) first — it covers the common cases.

## Development

- Lint the charts before opening a PR: `make lint`.
- Render templates locally to check a change: `helm template neio-leasingops ./leasingops/helm -f leasingops/helm/values-openshift.yaml`.
- Keep documentation in sync with the chart. If you change a value, a route, or a deployment step, update the README and the relevant file under `docs/`.
- The image tags in the README install command are pinned to a validated build (`YYYYMMDD.ZZ.XXXX`). Do not change them without coordinating with Codvo.

## Pull requests

- Keep changes focused and reviewable.
- Write a clear commit message describing what changed and why.
- Make sure `make lint` passes and any documentation links still resolve.

## License

By contributing, you agree that your contributions to the Helm chart and deployment configuration are licensed under Apache 2.0. The application container images are proprietary; see the "License" section of the [README](README.md#license).

## Contact

For access credentials or deployment questions, contact `bala@codvo.ai` or `indranil@codvo.ai`.
