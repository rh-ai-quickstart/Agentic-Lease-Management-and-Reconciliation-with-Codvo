#!/usr/bin/env bash
#
# generate-pull-secret.sh - Generate Kubernetes Image Pull Secret
#
# This script generates a Kubernetes secret for pulling images from
# the CODVO.AI container registry using a deployment token.
#
# Usage: ./generate-pull-secret.sh <TOKEN> [OPTIONS]
#
# Options:
#   --namespace, -n <NAME>     Kubernetes namespace (default: neio-leasingops)
#   --secret-name <NAME>       Secret name (default: quay-pull-secret)
#   --registry <URL>           Registry URL (default: quay.io/codvo)
#   --output, -o <FILE>        Output file path (default: stdout)
#   --apply                    Apply secret directly to cluster
#   --help, -h                 Show this help message
#
# Output:
#   Kubernetes Secret YAML for dockerconfigjson type
#
# Examples:
#   ./generate-pull-secret.sh eyJ... > pull-secret.yaml
#   ./generate-pull-secret.sh eyJ... --apply -n production
#   ./generate-pull-secret.sh eyJ... -o /tmp/secret.yaml
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output (only for stderr)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
NAMESPACE="neio-leasingops"
SECRET_NAME="quay-pull-secret"
REGISTRY="quay.io/codvo"
OUTPUT_FILE=""
APPLY_DIRECT=false
TOKEN=""

# Logging functions (to stderr to not interfere with YAML output)
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show help
show_help() {
    cat << EOF
NeIO LeasingOps Pull Secret Generator

Generates a Kubernetes image pull secret from a deployment token.

Usage: $(basename "$0") <TOKEN> [OPTIONS]

Arguments:
  TOKEN                        Deployment token from CODVO.AI

Options:
  --namespace, -n <NAME>       Kubernetes namespace (default: neio-leasingops)
  --secret-name <NAME>         Secret name (default: quay-pull-secret)
  --registry <URL>             Registry URL (default: quay.io/codvo)
  --output, -o <FILE>          Output file path (default: stdout)
  --apply                      Apply secret directly to cluster
  --help, -h                   Show this help message

Examples:
  # Generate and save to file
  $(basename "$0") eyJ... > pull-secret.yaml

  # Generate with custom namespace
  $(basename "$0") eyJ... --namespace production

  # Apply directly to cluster
  $(basename "$0") eyJ... --apply -n production

  # Save to specific file
  $(basename "$0") eyJ... -o /path/to/secret.yaml

Output Format:
  Generates a Kubernetes Secret of type 'kubernetes.io/dockerconfigjson'
  that can be used as an imagePullSecret in pods.

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace|-n)
                NAMESPACE="$2"
                shift 2
                ;;
            --secret-name)
                SECRET_NAME="$2"
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --output|-o)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --apply)
                APPLY_DIRECT=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "${TOKEN}" ]]; then
                    TOKEN="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v base64 &> /dev/null; then
        missing+=("base64")
    fi

    if [[ "${APPLY_DIRECT}" == "true" ]]; then
        if ! command -v kubectl &> /dev/null && ! command -v oc &> /dev/null; then
            missing+=("kubectl or oc")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

# Extract credentials from token
extract_credentials() {
    local token="$1"

    # The token itself serves as the password for registry authentication
    # Username is typically derived from the token or a fixed value
    # This follows the pattern used by many container registries

    # For JWT tokens, we can extract the customer_id as username
    local username="leasingops-customer"
    local password="${token}"

    # Try to extract customer_id from JWT payload if it's a valid JWT
    if [[ "${token}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        local payload_b64
        IFS='.' read -ra parts <<< "${token}"
        payload_b64="${parts[1]}"

        # Add padding if needed
        local padded="${payload_b64}"
        local mod=$((${#payload_b64} % 4))
        if [[ ${mod} -eq 2 ]]; then
            padded="${payload_b64}=="
        elif [[ ${mod} -eq 3 ]]; then
            padded="${payload_b64}="
        fi

        # Replace URL-safe characters
        padded="${padded//-/+}"
        padded="${padded//_//}"

        # Decode and extract customer_id
        local payload
        payload=$(echo "${padded}" | base64 -d 2>/dev/null || echo "")

        if [[ -n "${payload}" ]]; then
            local customer_id
            customer_id=$(echo "${payload}" | grep -o '"customer_id":"[^"]*"' 2>/dev/null | cut -d'"' -f4 || echo "")
            if [[ -n "${customer_id}" ]]; then
                username="${customer_id}"
            fi
        fi
    fi

    echo "${username}:${password}"
}

# Generate Docker config JSON
generate_docker_config() {
    local registry="$1"
    local credentials="$2"

    local username password
    username="${credentials%%:*}"
    password="${credentials#*:}"

    # Create auth string (base64 of username:password)
    local auth
    auth=$(echo -n "${username}:${password}" | base64 | tr -d '\n')

    # Extract registry server (without protocol and path)
    local server="${registry}"
    server="${server#https://}"
    server="${server#http://}"
    server="${server%%/*}"

    # Generate Docker config JSON
    cat << EOF
{
    "auths": {
        "${server}": {
            "auth": "${auth}",
            "email": "deployment@codvo.ai"
        }
    }
}
EOF
}

# Generate Kubernetes secret YAML
generate_secret_yaml() {
    local namespace="$1"
    local secret_name="$2"
    local docker_config="$3"

    # Base64 encode the Docker config
    local docker_config_b64
    docker_config_b64=$(echo -n "${docker_config}" | base64 | tr -d '\n')

    # Get current timestamp for annotation
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: neio-leasingops
    app.kubernetes.io/component: pull-secret
    app.kubernetes.io/managed-by: neio-deploy-scripts
  annotations:
    codvo.ai/generated-at: "${timestamp}"
    codvo.ai/generator: "generate-pull-secret.sh"
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${docker_config_b64}
EOF
}

# Apply secret to cluster
apply_secret() {
    local yaml="$1"

    local cli_tool="kubectl"
    if command -v oc &> /dev/null; then
        cli_tool="oc"
    fi

    log_info "Applying secret to cluster using ${cli_tool}..."

    # Create namespace if it doesn't exist
    if ! ${cli_tool} get namespace "${NAMESPACE}" &> /dev/null; then
        log_info "Creating namespace: ${NAMESPACE}"
        ${cli_tool} create namespace "${NAMESPACE}" 2>/dev/null || true
    fi

    # Apply the secret
    if echo "${yaml}" | ${cli_tool} apply -f -; then
        log_success "Secret '${SECRET_NAME}' applied to namespace '${NAMESPACE}'"
    else
        log_error "Failed to apply secret"
        exit 1
    fi
}

# Main function
main() {
    check_dependencies
    parse_args "$@"

    if [[ -z "${TOKEN}" ]]; then
        log_error "Token is required"
        show_help
        exit 1
    fi

    # Validate token format (basic check)
    if [[ ${#TOKEN} -lt 20 ]]; then
        log_error "Token appears too short to be valid"
        exit 1
    fi

    log_info "Generating pull secret for registry: ${REGISTRY}"

    # Extract credentials from token
    local credentials
    credentials=$(extract_credentials "${TOKEN}")

    # Generate Docker config
    local docker_config
    docker_config=$(generate_docker_config "${REGISTRY}" "${credentials}")

    # Generate Kubernetes secret YAML
    local secret_yaml
    secret_yaml=$(generate_secret_yaml "${NAMESPACE}" "${SECRET_NAME}" "${docker_config}")

    # Output or apply
    if [[ "${APPLY_DIRECT}" == "true" ]]; then
        apply_secret "${secret_yaml}"
    elif [[ -n "${OUTPUT_FILE}" ]]; then
        echo "${secret_yaml}" > "${OUTPUT_FILE}"
        log_success "Secret written to: ${OUTPUT_FILE}"
    else
        # Output to stdout
        echo "${secret_yaml}"
    fi

    log_info "Usage in deployment:"
    log_info "  Add to pod spec:"
    log_info "    imagePullSecrets:"
    log_info "      - name: ${SECRET_NAME}"
}

# Run main
main "$@"
