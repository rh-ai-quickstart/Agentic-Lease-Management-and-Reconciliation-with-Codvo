#!/usr/bin/env bash
#
# validate-token.sh - JWT Token Validation for NeIO LeasingOps
#
# This script validates deployment tokens issued by CODVO.AI.
# It checks expiration, customer ID, deployment limits, and allowed images.
#
# Usage: ./validate-token.sh <JWT_TOKEN> [OPTIONS]
#
# Options:
#   --chart-version <VERSION>  Chart version to validate against allowed_images
#   --verbose, -v              Enable verbose output
#   --quiet, -q                Suppress all output except errors
#   --json                     Output validation results as JSON
#
# Exit Codes:
#   0  - Token is valid
#   1  - Token format invalid
#   2  - Token expired
#   3  - Customer ID missing or invalid
#   4  - Deployment limit exceeded
#   5  - Chart version not in allowed_images
#   6  - Token signature invalid (if verification enabled)
#   10 - Missing dependencies (jq, base64)
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Default values
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
CHART_VERSION=""
TOKEN=""

# Exit codes
EXIT_OK=0
EXIT_INVALID_FORMAT=1
EXIT_EXPIRED=2
EXIT_INVALID_CUSTOMER=3
EXIT_LIMIT_EXCEEDED=4
EXIT_VERSION_NOT_ALLOWED=5
EXIT_INVALID_SIGNATURE=6
EXIT_MISSING_DEPS=10

# Logging functions
log_info() {
    if [[ "${QUIET}" != "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [[ "${QUIET}" != "true" ]]; then
        echo -e "${GREEN}[OK]${NC} $1"
    fi
}

log_warn() {
    if [[ "${QUIET}" != "true" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]] && [[ "${QUIET}" != "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Show help
show_help() {
    cat << EOF
NeIO LeasingOps Token Validator

Usage: $(basename "$0") <JWT_TOKEN> [OPTIONS]

Arguments:
  JWT_TOKEN                    The deployment token to validate

Options:
  --chart-version <VERSION>    Chart version to validate against allowed_images
  --verbose, -v                Enable verbose output
  --quiet, -q                  Suppress all output except errors
  --json                       Output validation results as JSON
  --help, -h                   Show this help message

Exit Codes:
  0   Token is valid
  1   Token format invalid (not a valid JWT)
  2   Token expired
  3   Customer ID missing or invalid
  4   Deployment limit exceeded
  5   Chart version not in allowed_images
  6   Token signature invalid
  10  Missing dependencies

Examples:
  $(basename "$0") eyJ...
  $(basename "$0") eyJ... --chart-version 1.0.0 -v
  $(basename "$0") eyJ... --json --quiet

Token Claims Expected:
  - exp:              Expiration timestamp (Unix epoch)
  - customer_id:      Customer identifier
  - deployment_limit: Maximum number of deployments allowed
  - allowed_images:   Array of allowed image versions

For token issuance, contact: support@codvo.ai
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --chart-version)
                CHART_VERSION="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --quiet|-q)
                QUIET=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
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

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if ! command -v base64 &> /dev/null; then
        missing+=("base64")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo "Install with:"
        echo "  macOS: brew install jq"
        echo "  Ubuntu: apt-get install jq"
        echo "  RHEL: yum install jq"
        exit ${EXIT_MISSING_DEPS}
    fi
}

# Base64 URL decode
base64_url_decode() {
    local input="$1"
    local padded

    # Add padding if needed
    local mod=$((${#input} % 4))
    if [[ ${mod} -eq 2 ]]; then
        padded="${input}=="
    elif [[ ${mod} -eq 3 ]]; then
        padded="${input}="
    else
        padded="${input}"
    fi

    # Replace URL-safe characters
    padded="${padded//-/+}"
    padded="${padded//_//}"

    # Decode
    echo "${padded}" | base64 -d 2>/dev/null
}

# Decode JWT token
decode_jwt() {
    local token="$1"

    # Split token into parts
    IFS='.' read -ra parts <<< "${token}"

    if [[ ${#parts[@]} -ne 3 ]]; then
        log_error "Invalid JWT format: expected 3 parts, got ${#parts[@]}"
        return ${EXIT_INVALID_FORMAT}
    fi

    local header payload

    # Decode header
    header=$(base64_url_decode "${parts[0]}")
    if [[ -z "${header}" ]]; then
        log_error "Failed to decode JWT header"
        return ${EXIT_INVALID_FORMAT}
    fi

    # Decode payload
    payload=$(base64_url_decode "${parts[1]}")
    if [[ -z "${payload}" ]]; then
        log_error "Failed to decode JWT payload"
        return ${EXIT_INVALID_FORMAT}
    fi

    # Validate JSON
    if ! echo "${header}" | jq . &> /dev/null; then
        log_error "Invalid JSON in JWT header"
        return ${EXIT_INVALID_FORMAT}
    fi

    if ! echo "${payload}" | jq . &> /dev/null; then
        log_error "Invalid JSON in JWT payload"
        return ${EXIT_INVALID_FORMAT}
    fi

    log_verbose "Header: ${header}"
    log_verbose "Payload: ${payload}"

    echo "${payload}"
}

# Validate token expiration
validate_expiration() {
    local payload="$1"

    local exp
    exp=$(echo "${payload}" | jq -r '.exp // empty')

    if [[ -z "${exp}" ]]; then
        log_warn "No expiration claim (exp) found in token"
        return 0  # Allow tokens without expiration for now
    fi

    local current_time
    current_time=$(date +%s)

    log_verbose "Token expires at: ${exp} ($(date -r "${exp}" 2>/dev/null || date -d "@${exp}" 2>/dev/null || echo "unknown"))"
    log_verbose "Current time: ${current_time}"

    if [[ ${exp} -lt ${current_time} ]]; then
        local expired_ago=$((current_time - exp))
        log_error "Token expired ${expired_ago} seconds ago"
        log_error "Expiration: $(date -r "${exp}" 2>/dev/null || date -d "@${exp}" 2>/dev/null || echo "unknown")"
        return ${EXIT_EXPIRED}
    fi

    local remaining=$((exp - current_time))
    local days=$((remaining / 86400))
    local hours=$(((remaining % 86400) / 3600))

    if [[ ${remaining} -lt 86400 ]]; then
        log_warn "Token expires in less than 24 hours (${hours} hours remaining)"
    else
        log_success "Token valid for ${days} days, ${hours} hours"
    fi

    return 0
}

# Validate customer ID
validate_customer_id() {
    local payload="$1"

    local customer_id
    customer_id=$(echo "${payload}" | jq -r '.customer_id // .sub // .client_id // empty')

    if [[ -z "${customer_id}" ]]; then
        log_error "No customer identifier found in token (checked: customer_id, sub, client_id)"
        return ${EXIT_INVALID_CUSTOMER}
    fi

    # Basic validation: check it's not empty and has reasonable format
    if [[ "${customer_id}" =~ ^[a-zA-Z0-9_-]{3,64}$ ]]; then
        log_success "Customer ID: ${customer_id}"
    else
        log_warn "Customer ID format may be non-standard: ${customer_id}"
    fi

    return 0
}

# Validate deployment limit
validate_deployment_limit() {
    local payload="$1"

    local deployment_limit
    deployment_limit=$(echo "${payload}" | jq -r '.deployment_limit // .max_deployments // empty')

    if [[ -z "${deployment_limit}" ]]; then
        log_verbose "No deployment limit specified in token"
        return 0
    fi

    if ! [[ "${deployment_limit}" =~ ^[0-9]+$ ]]; then
        log_error "Invalid deployment limit format: ${deployment_limit}"
        return ${EXIT_LIMIT_EXCEEDED}
    fi

    log_success "Deployment limit: ${deployment_limit}"

    # Check current deployments (would need external tracking)
    local current_deployments
    current_deployments=$(echo "${payload}" | jq -r '.current_deployments // 0')

    if [[ ${current_deployments} -ge ${deployment_limit} ]]; then
        log_error "Deployment limit exceeded: ${current_deployments}/${deployment_limit}"
        return ${EXIT_LIMIT_EXCEEDED}
    fi

    log_info "Deployments used: ${current_deployments}/${deployment_limit}"

    return 0
}

# Validate allowed images
validate_allowed_images() {
    local payload="$1"
    local chart_version="$2"

    if [[ -z "${chart_version}" ]]; then
        log_verbose "No chart version specified, skipping image validation"
        return 0
    fi

    local allowed_images
    allowed_images=$(echo "${payload}" | jq -r '.allowed_images // empty')

    if [[ -z "${allowed_images}" ]] || [[ "${allowed_images}" == "null" ]]; then
        log_verbose "No allowed_images restriction in token"
        return 0
    fi

    # Check if chart version is in allowed images
    local version_allowed
    version_allowed=$(echo "${payload}" | jq -r --arg v "${chart_version}" '.allowed_images | if type == "array" then contains([$v]) else . == $v end')

    if [[ "${version_allowed}" == "true" ]]; then
        log_success "Chart version ${chart_version} is allowed"
    else
        log_error "Chart version ${chart_version} is not in allowed_images"
        log_error "Allowed versions: ${allowed_images}"
        return ${EXIT_VERSION_NOT_ALLOWED}
    fi

    return 0
}

# Output JSON result
output_json() {
    local payload="$1"
    local valid="$2"
    local error_code="$3"
    local error_msg="${4:-}"

    local exp customer_id deployment_limit allowed_images

    exp=$(echo "${payload}" | jq -r '.exp // null')
    customer_id=$(echo "${payload}" | jq -r '.customer_id // .sub // .client_id // null')
    deployment_limit=$(echo "${payload}" | jq -r '.deployment_limit // null')
    allowed_images=$(echo "${payload}" | jq -c '.allowed_images // null')

    jq -n \
        --argjson valid "${valid}" \
        --argjson error_code "${error_code}" \
        --arg error_msg "${error_msg}" \
        --argjson exp "${exp:-null}" \
        --arg customer_id "${customer_id:-}" \
        --argjson deployment_limit "${deployment_limit:-null}" \
        --argjson allowed_images "${allowed_images:-null}" \
        '{
            valid: $valid,
            error_code: $error_code,
            error_message: $error_msg,
            claims: {
                exp: $exp,
                customer_id: $customer_id,
                deployment_limit: $deployment_limit,
                allowed_images: $allowed_images
            }
        }'
}

# Main validation
main() {
    check_dependencies
    parse_args "$@"

    if [[ -z "${TOKEN}" ]]; then
        log_error "Token is required"
        show_help
        exit ${EXIT_INVALID_FORMAT}
    fi

    if [[ "${QUIET}" != "true" ]] && [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${BOLD}NeIO LeasingOps Token Validator${NC}"
        echo ""
    fi

    # Decode token
    local payload
    if ! payload=$(decode_jwt "${TOKEN}"); then
        if [[ "${JSON_OUTPUT}" == "true" ]]; then
            output_json "{}" "false" ${EXIT_INVALID_FORMAT} "Invalid JWT format"
        fi
        exit ${EXIT_INVALID_FORMAT}
    fi

    local error_code=0
    local error_msg=""

    # Run all validations
    log_info "Validating token claims..."
    echo ""

    # Validate expiration
    if ! validate_expiration "${payload}"; then
        error_code=${EXIT_EXPIRED}
        error_msg="Token expired"
    fi

    # Validate customer ID
    if [[ ${error_code} -eq 0 ]]; then
        if ! validate_customer_id "${payload}"; then
            error_code=${EXIT_INVALID_CUSTOMER}
            error_msg="Invalid or missing customer ID"
        fi
    fi

    # Validate deployment limit
    if [[ ${error_code} -eq 0 ]]; then
        if ! validate_deployment_limit "${payload}"; then
            error_code=${EXIT_LIMIT_EXCEEDED}
            error_msg="Deployment limit exceeded"
        fi
    fi

    # Validate allowed images
    if [[ ${error_code} -eq 0 ]]; then
        if ! validate_allowed_images "${payload}" "${CHART_VERSION}"; then
            error_code=${EXIT_VERSION_NOT_ALLOWED}
            error_msg="Chart version not allowed"
        fi
    fi

    # Output result
    if [[ "${JSON_OUTPUT}" == "true" ]]; then
        if [[ ${error_code} -eq 0 ]]; then
            output_json "${payload}" "true" 0 ""
        else
            output_json "${payload}" "false" "${error_code}" "${error_msg}"
        fi
    else
        echo ""
        if [[ ${error_code} -eq 0 ]]; then
            log_success "Token validation successful"
        else
            log_error "Token validation failed: ${error_msg}"
        fi
    fi

    exit ${error_code}
}

# Run main
main "$@"
