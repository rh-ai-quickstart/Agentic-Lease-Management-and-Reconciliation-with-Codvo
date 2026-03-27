#!/usr/bin/env bash
#
# deploy.sh - One-click deployment script for NeIO LeasingOps
#
# Usage: ./deploy.sh --token <JWT_TOKEN> [OPTIONS]
#
# Options:
#   --token, -t        JWT deployment token (required)
#   --namespace, -n    Kubernetes namespace (default: neio-leasingops)
#   --values, -f       Custom values file path
#   --chart-path       Path to Helm chart (default: ../leasingops/helm)
#   --with-deps        Install dependencies (PostgreSQL, Redis, MinIO)
#   --dry-run          Print what would be deployed without executing
#   --skip-validation  Skip token validation (not recommended)
#   --timeout          Helm deployment timeout (default: 10m)
#   --help, -h         Show this help message
#
# Environment Variables:
#   KUBECONFIG         Path to kubeconfig file
#   NEIO_TOKEN         Alternative way to provide the deployment token
#
# Examples:
#   ./deploy.sh --token eyJ... --namespace production
#   ./deploy.sh -t eyJ... -f custom-values.yaml --with-deps
#   NEIO_TOKEN=eyJ... ./deploy.sh --namespace staging
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default values
NAMESPACE="neio-leasingops"
CHART_PATH="${SCRIPT_DIR}/../leasingops/helm"
VALUES_FILE=""
INSTALL_DEPS=false
DRY_RUN=false
SKIP_VALIDATION=false
TIMEOUT="10m"
TOKEN="${NEIO_TOKEN:-}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}==> $1${NC}"
}

# Print banner
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   ███╗   ██╗███████╗██╗ ██████╗                              ║"
    echo "║   ████╗  ██║██╔════╝██║██╔═══██╗                             ║"
    echo "║   ██╔██╗ ██║█████╗  ██║██║   ██║                             ║"
    echo "║   ██║╚██╗██║██╔══╝  ██║██║   ██║                             ║"
    echo "║   ██║ ╚████║███████╗██║╚██████╔╝                             ║"
    echo "║   ╚═╝  ╚═══╝╚══════╝╚═╝ ╚═════╝                              ║"
    echo "║                                                               ║"
    echo "║   LeasingOps - AI-Powered Aircraft Leasing Operations        ║"
    echo "║   Version: 1.0.0                                              ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Show help
show_help() {
    cat << EOF
NeIO LeasingOps Deployment Script

Usage: $(basename "$0") --token <JWT_TOKEN> [OPTIONS]

Required:
  --token, -t <TOKEN>      JWT deployment token from CODVO.AI

Options:
  --namespace, -n <NAME>   Kubernetes namespace (default: neio-leasingops)
  --values, -f <FILE>      Custom Helm values file
  --chart-path <PATH>      Path to Helm chart (default: ../leasingops/helm)
  --with-deps              Install dependencies (PostgreSQL, Redis, MinIO)
  --dry-run                Show what would be deployed without executing
  --skip-validation        Skip token validation (not recommended)
  --timeout <DURATION>     Helm deployment timeout (default: 10m)
  --help, -h               Show this help message

Environment Variables:
  KUBECONFIG               Path to kubeconfig file
  NEIO_TOKEN               Alternative way to provide the deployment token

Examples:
  # Basic deployment
  $(basename "$0") --token eyJ...

  # Deploy to custom namespace with dependencies
  $(basename "$0") -t eyJ... -n production --with-deps

  # Deploy with custom values file
  $(basename "$0") -t eyJ... -f my-values.yaml

  # Dry run to preview deployment
  $(basename "$0") -t eyJ... --dry-run

For more information, visit: https://codvo.ai/docs/leasingops
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --token|-t)
                TOKEN="$2"
                shift 2
                ;;
            --namespace|-n)
                NAMESPACE="$2"
                shift 2
                ;;
            --values|-f)
                VALUES_FILE="$2"
                shift 2
                ;;
            --chart-path)
                CHART_PATH="$2"
                shift 2
                ;;
            --with-deps)
                INSTALL_DEPS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-validation)
                SKIP_VALIDATION=true
                shift
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Validate prerequisites
validate_prerequisites() {
    log_step "Validating Prerequisites"

    local missing_tools=()

    # Check for Helm
    if command -v helm &> /dev/null; then
        local helm_version
        helm_version=$(helm version --short 2>/dev/null | head -1)
        log_info "Helm found: ${helm_version}"
    else
        missing_tools+=("helm")
    fi

    # Check for kubectl or oc
    if command -v oc &> /dev/null; then
        local oc_version
        oc_version=$(oc version --client 2>/dev/null | head -1)
        log_info "OpenShift CLI found: ${oc_version}"
    elif command -v kubectl &> /dev/null; then
        local kubectl_version
        kubectl_version=$(kubectl version --client --short 2>/dev/null | head -1)
        log_info "kubectl found: ${kubectl_version}"
    else
        missing_tools+=("kubectl or oc")
    fi

    # Check for jq (needed for token validation)
    if command -v jq &> /dev/null; then
        log_info "jq found: $(jq --version)"
    else
        missing_tools+=("jq")
    fi

    # Check for base64
    if command -v base64 &> /dev/null; then
        log_info "base64 found"
    else
        missing_tools+=("base64")
    fi

    # Report missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Installation instructions:"
        echo "  Helm:    https://helm.sh/docs/intro/install/"
        echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "  oc:      https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
        echo "  jq:      https://stedolan.github.io/jq/download/"
        exit 1
    fi

    # Verify cluster connectivity
    log_info "Verifying cluster connectivity..."
    if command -v oc &> /dev/null; then
        if ! oc whoami &> /dev/null; then
            log_error "Not logged into OpenShift cluster. Run 'oc login' first."
            exit 1
        fi
        log_info "Connected to cluster as: $(oc whoami)"
        log_info "Server: $(oc whoami --show-server)"
    elif command -v kubectl &> /dev/null; then
        if ! kubectl cluster-info &> /dev/null; then
            log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
            exit 1
        fi
        local cluster_info
        cluster_info=$(kubectl cluster-info 2>/dev/null | head -1)
        log_info "Cluster: ${cluster_info}"
    fi

    # Verify chart path exists
    if [[ ! -d "${CHART_PATH}" ]]; then
        log_error "Helm chart not found at: ${CHART_PATH}"
        exit 1
    fi
    log_info "Chart path: ${CHART_PATH}"

    # Verify values file if specified
    if [[ -n "${VALUES_FILE}" ]] && [[ ! -f "${VALUES_FILE}" ]]; then
        log_error "Values file not found: ${VALUES_FILE}"
        exit 1
    fi

    log_success "All prerequisites validated"
}

# Validate deployment token
validate_token() {
    log_step "Validating Deployment Token"

    if [[ -z "${TOKEN}" ]]; then
        log_error "Deployment token is required. Use --token or set NEIO_TOKEN environment variable."
        exit 1
    fi

    if [[ "${SKIP_VALIDATION}" == "true" ]]; then
        log_warn "Token validation skipped (--skip-validation)"
        return 0
    fi

    # Call validate-token.sh
    if [[ -x "${SCRIPT_DIR}/validate-token.sh" ]]; then
        if ! "${SCRIPT_DIR}/validate-token.sh" "${TOKEN}" --chart-version "1.0.0"; then
            log_error "Token validation failed"
            exit 1
        fi
        log_success "Token validated successfully"
    else
        log_warn "validate-token.sh not found or not executable, skipping detailed validation"

        # Basic JWT structure check
        local parts
        IFS='.' read -ra parts <<< "${TOKEN}"
        if [[ ${#parts[@]} -ne 3 ]]; then
            log_error "Invalid token format (not a valid JWT)"
            exit 1
        fi
        log_info "Token format appears valid (JWT structure check passed)"
    fi
}

# Generate and apply pull secret
generate_pull_secret() {
    log_step "Generating Image Pull Secret"

    local secret_file
    secret_file=$(mktemp)

    # Call generate-pull-secret.sh
    if [[ -x "${SCRIPT_DIR}/generate-pull-secret.sh" ]]; then
        "${SCRIPT_DIR}/generate-pull-secret.sh" "${TOKEN}" --namespace "${NAMESPACE}" > "${secret_file}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "Dry run - would apply pull secret:"
            cat "${secret_file}"
        else
            # Create namespace if it doesn't exist
            if command -v oc &> /dev/null; then
                if ! oc get namespace "${NAMESPACE}" &> /dev/null; then
                    log_info "Creating namespace: ${NAMESPACE}"
                    oc create namespace "${NAMESPACE}" 2>/dev/null || true
                fi
                oc apply -f "${secret_file}"
            else
                if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
                    log_info "Creating namespace: ${NAMESPACE}"
                    kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
                fi
                kubectl apply -f "${secret_file}"
            fi
            log_success "Pull secret applied to namespace ${NAMESPACE}"
        fi

        rm -f "${secret_file}"
    else
        log_warn "generate-pull-secret.sh not found, skipping pull secret generation"
        log_info "Ensure imageCredentials.dockerconfigjson is set in values file"
    fi
}

# Install dependencies
install_dependencies() {
    log_step "Installing Dependencies"

    if [[ "${INSTALL_DEPS}" != "true" ]]; then
        log_info "Skipping dependency installation (use --with-deps to install)"
        return 0
    fi

    # Add Bitnami repo
    log_info "Adding Bitnami Helm repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update

    local helm_cmd="helm"
    if [[ "${DRY_RUN}" == "true" ]]; then
        helm_cmd="helm --dry-run"
    fi

    # Install PostgreSQL
    log_info "Installing PostgreSQL..."
    ${helm_cmd} upgrade --install postgresql bitnami/postgresql \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --set auth.database=leasingops \
        --set auth.username=leasingops \
        --set primary.persistence.size=10Gi \
        --wait \
        --timeout "${TIMEOUT}" || log_warn "PostgreSQL installation failed or already exists"

    # Install Redis
    log_info "Installing Redis..."
    ${helm_cmd} upgrade --install redis bitnami/redis \
        --namespace "${NAMESPACE}" \
        --set architecture=standalone \
        --set master.persistence.size=5Gi \
        --wait \
        --timeout "${TIMEOUT}" || log_warn "Redis installation failed or already exists"

    # Install MinIO
    log_info "Installing MinIO..."
    ${helm_cmd} upgrade --install minio bitnami/minio \
        --namespace "${NAMESPACE}" \
        --set persistence.size=20Gi \
        --wait \
        --timeout "${TIMEOUT}" || log_warn "MinIO installation failed or already exists"

    log_success "Dependencies installed"
}

# Deploy main chart
deploy_chart() {
    log_step "Deploying NeIO LeasingOps"

    # Build Helm command
    local helm_args=()
    helm_args+=("upgrade" "--install" "neio-leasingops")
    helm_args+=("${CHART_PATH}")
    helm_args+=("--namespace" "${NAMESPACE}")
    helm_args+=("--create-namespace")
    helm_args+=("--timeout" "${TIMEOUT}")

    # Add values file if specified
    if [[ -n "${VALUES_FILE}" ]]; then
        helm_args+=("-f" "${VALUES_FILE}")
    fi

    # Set deployment token
    helm_args+=("--set" "imageCredentials.create=true")

    # Add dry-run flag if needed
    if [[ "${DRY_RUN}" == "true" ]]; then
        helm_args+=("--dry-run")
        log_info "Dry run mode - showing what would be deployed:"
    fi

    # Add wait flag
    helm_args+=("--wait")

    log_info "Running: helm ${helm_args[*]}"

    # Update dependencies
    log_info "Updating Helm dependencies..."
    helm dependency update "${CHART_PATH}" 2>/dev/null || log_warn "Failed to update dependencies, continuing..."

    # Execute deployment
    if helm "${helm_args[@]}"; then
        if [[ "${DRY_RUN}" != "true" ]]; then
            log_success "NeIO LeasingOps deployed successfully"
        fi
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Run health check
run_health_check() {
    log_step "Running Health Check"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "Skipping health check in dry-run mode"
        return 0
    fi

    # Call health-check.sh
    if [[ -x "${SCRIPT_DIR}/health-check.sh" ]]; then
        if "${SCRIPT_DIR}/health-check.sh" --namespace "${NAMESPACE}"; then
            log_success "Health check passed"
        else
            log_warn "Health check reported issues - deployment may still be starting"
        fi
    else
        log_warn "health-check.sh not found, performing basic health check"

        # Basic pod check
        log_info "Checking pod status..."
        if command -v oc &> /dev/null; then
            oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops
        else
            kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops
        fi
    fi
}

# Print access URLs
print_access_info() {
    log_step "Access Information"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "Dry run mode - access URLs would be printed after actual deployment"
        return 0
    fi

    echo ""
    echo -e "${BOLD}NeIO LeasingOps has been deployed successfully!${NC}"
    echo ""

    # Get service URLs
    local cli_tool="kubectl"
    if command -v oc &> /dev/null; then
        cli_tool="oc"
    fi

    echo -e "${BOLD}Services:${NC}"
    ${cli_tool} get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops 2>/dev/null || true

    echo ""

    # Check for routes (OpenShift) or ingress (Kubernetes)
    if command -v oc &> /dev/null; then
        echo -e "${BOLD}Routes:${NC}"
        if oc get routes -n "${NAMESPACE}" 2>/dev/null | grep -q neio-leasingops; then
            oc get routes -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops

            local api_route
            api_route=$(oc get route -n "${NAMESPACE}" -l app.kubernetes.io/component=api -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
            if [[ -n "${api_route}" ]]; then
                echo ""
                echo -e "${BOLD}Access URLs:${NC}"
                echo "  API:      https://${api_route}"
                echo "  Health:   https://${api_route}/health"
                echo "  Docs:     https://${api_route}/docs"
            fi
        else
            echo "  No routes found. Create routes or use port-forward for access."
        fi
    else
        echo -e "${BOLD}Ingress:${NC}"
        if kubectl get ingress -n "${NAMESPACE}" 2>/dev/null | grep -q neio-leasingops; then
            kubectl get ingress -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops
        else
            echo "  No ingress found. Create ingress or use port-forward for access."
        fi
    fi

    echo ""
    echo -e "${BOLD}Quick Access (Port Forward):${NC}"
    echo "  kubectl port-forward svc/neio-leasingops-api 8000:8000 -n ${NAMESPACE}"
    echo "  Then access: http://localhost:8000"
    echo ""
    echo -e "${BOLD}View Logs:${NC}"
    echo "  ${cli_tool} logs -f -l app.kubernetes.io/name=neio-leasingops -n ${NAMESPACE}"
    echo ""
    echo -e "${BOLD}Documentation:${NC}"
    echo "  https://codvo.ai/docs/leasingops"
    echo ""
}

# Main function
main() {
    print_banner
    parse_args "$@"
    validate_prerequisites
    validate_token
    generate_pull_secret
    install_dependencies
    deploy_chart
    run_health_check
    print_access_info

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo ""
        log_info "This was a dry run. No changes were made."
        log_info "Remove --dry-run to perform actual deployment."
    fi
}

# Run main
main "$@"
