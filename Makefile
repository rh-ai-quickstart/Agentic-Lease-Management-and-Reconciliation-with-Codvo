# NeIO LeasingOps — Deployment Makefile
#
# For RSDP automated deployments, RSDP calls helm directly with values-rsdp.yaml.
# This Makefile is for human-driven / manual installs only.
#
# Quick start:
#   make deploy NAMESPACE=neio-leasingops VALUES=my-values.yaml
#
# RSDP path (automated, no Makefile):
#   helm install neio-infra ./helm/infra --namespace neio-leasingops --create-namespace --values <infra-values>
#   helm install neio-leasingops ./leasingops/helm --namespace neio-leasingops --values values-rsdp.yaml

# ===== Configurable defaults =====
NAMESPACE      ?= neio-leasingops
RELEASE_INFRA  ?= neio-infra
RELEASE_APP    ?= neio-leasingops
HELM_INFRA     := ./helm/infra
HELM_APP       := ./leasingops/helm
VALUES         ?= values-rsdp.yaml
INFRA_VALUES   ?= helm/infra/values.yaml
TIMEOUT        ?= 10m

# ===== Colors =====
BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[32m
CYAN  := \033[36m

.DEFAULT_GOAL := help

.PHONY: help deps-update lint infra app deploy destroy status

## help: Show this help message
help:
	@echo ""
	@echo "$(BOLD)NeIO LeasingOps — Deployment Commands$(RESET)"
	@echo ""
	@echo "$(CYAN)  make infra$(RESET)   — Install infra chart (PostgreSQL, Redis, MinIO)"
	@echo "$(CYAN)  make app$(RESET)     — Install app chart (assumes infra already present)"
	@echo "$(CYAN)  make deploy$(RESET)  — Install infra then app (full stack)"
	@echo "$(CYAN)  make destroy$(RESET) — Uninstall both releases"
	@echo "$(CYAN)  make lint$(RESET)    — Lint all Helm charts"
	@echo "$(CYAN)  make status$(RESET)  — Show rollout status"
	@echo ""
	@echo "$(BOLD)Configurable variables:$(RESET)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  RELEASE_APP=$(RELEASE_APP)"
	@echo "  VALUES=$(VALUES)"
	@echo "  LLM_URL, LLM_API_TOKEN, LLM_MODEL  (can be passed as env vars)"
	@echo ""
	@echo "$(BOLD)Example (with LLM override):$(RESET)"
	@echo "  make deploy LLM_URL=https://... LLM_API_TOKEN=sk-... LLM_MODEL=llama-3-70b"
	@echo ""

## deps-update: Update Helm chart dependencies
deps-update:
	@echo "$(BOLD)Updating Helm dependencies...$(RESET)"
	helm repo add bitnami https://charts.bitnami.com/bitnami
	helm repo update
	helm dependency update $(HELM_INFRA)
	helm dependency update $(HELM_APP)

## lint: Lint all Helm charts
lint:
	@echo "$(BOLD)Linting charts...$(RESET)"
	helm lint $(HELM_INFRA) --values $(INFRA_VALUES)
	helm lint $(HELM_APP) --values $(VALUES)
	@echo "$(GREEN)All charts passed lint.$(RESET)"

## infra: Install/upgrade the infrastructure chart
infra: deps-update
	@echo "$(BOLD)Deploying infrastructure: $(RELEASE_INFRA)$(RESET)"
	helm upgrade --install $(RELEASE_INFRA) $(HELM_INFRA) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--values $(INFRA_VALUES) \
		--wait \
		--timeout $(TIMEOUT)
	@echo "$(GREEN)Infrastructure deployed.$(RESET)"

## app: Install/upgrade the application chart (assumes infra is already present)
app: deps-update
	@echo "$(BOLD)Deploying application: $(RELEASE_APP)$(RESET)"
	@LLM_OVERRIDES=""; \
	if [ -n "$(LLM_URL)" ];       then LLM_OVERRIDES="$$LLM_OVERRIDES --set llm.url=$(LLM_URL)"; fi; \
	if [ -n "$(LLM_API_TOKEN)" ]; then LLM_OVERRIDES="$$LLM_OVERRIDES --set llm.apiToken=$(LLM_API_TOKEN)"; fi; \
	if [ -n "$(LLM_MODEL)" ];     then LLM_OVERRIDES="$$LLM_OVERRIDES --set llm.model=$(LLM_MODEL)"; fi; \
	helm upgrade --install $(RELEASE_APP) $(HELM_APP) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--values $(VALUES) \
		$$LLM_OVERRIDES \
		--wait \
		--timeout $(TIMEOUT)
	@echo "$(GREEN)Application deployed.$(RESET)"

## deploy: Full deployment — infra then app
deploy: infra app
	@echo "$(GREEN)$(BOLD)Full stack deployed successfully.$(RESET)"
	@$(MAKE) status

## destroy: Uninstall both releases (prompts for confirmation)
destroy:
	@echo "$(BOLD)WARNING: This will uninstall both $(RELEASE_APP) and $(RELEASE_INFRA) from namespace $(NAMESPACE).$(RESET)"
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	-helm uninstall $(RELEASE_APP) --namespace $(NAMESPACE)
	-helm uninstall $(RELEASE_INFRA) --namespace $(NAMESPACE)
	@echo "$(GREEN)Releases uninstalled.$(RESET)"

## status: Show rollout status for all deployments
status:
	@echo "$(BOLD)Deployment status in namespace: $(NAMESPACE)$(RESET)"
	-kubectl rollout status deployment -n $(NAMESPACE) --timeout=2m
	@echo ""
	-kubectl get pods -n $(NAMESPACE)
