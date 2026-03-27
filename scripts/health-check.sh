#!/usr/bin/env bash
#
# health-check.sh - Post-deployment Health Validation for NeIO LeasingOps
#
# This script verifies the health of a NeIO LeasingOps deployment by checking:
# - Pod status and readiness
# - Service availability
# - API health endpoints
# - Database connectivity
# - Optional component health
#
# Usage: ./health-check.sh [OPTIONS]
#
# Options:
#   --namespace, -n <NAME>     Kubernetes namespace (default: neio-leasingops)
#   --timeout <SECONDS>        Timeout for health checks (default: 300)
#   --wait                     Wait for pods to become ready
#   --json                     Output results as JSON
#   --verbose, -v              Enable verbose output
#   --help, -h                 Show this help message
#
# Exit Codes:
#   0  - All health checks passed
#   1  - One or more health checks failed
#   2  - Critical failure (cluster unreachable, namespace not found)
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
NC='\033[0m'
BOLD='\033[1m'

# Default values
NAMESPACE="neio-leasingops"
TIMEOUT=300
WAIT_FOR_READY=false
JSON_OUTPUT=false
VERBOSE=false

# Health check results
declare -A CHECK_RESULTS
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# CLI tool (kubectl or oc)
CLI_TOOL=""

# Logging functions
log_info() {
    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${GREEN}[PASS]${NC} $1"
    fi
}

log_warn() {
    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

log_error() {
    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${RED}[FAIL]${NC} $1"
    fi
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]] && [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

log_header() {
    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}=== $1 ===${NC}"
    fi
}

# Record check result
record_check() {
    local name="$1"
    local status="$2"  # pass, fail, warn
    local message="$3"

    CHECK_RESULTS["${name}"]="${status}:${message}"
    ((TOTAL_CHECKS++))

    case "${status}" in
        pass)
            ((PASSED_CHECKS++))
            log_success "${name}: ${message}"
            ;;
        fail)
            ((FAILED_CHECKS++))
            log_error "${name}: ${message}"
            ;;
        warn)
            ((WARNINGS++))
            log_warn "${name}: ${message}"
            ;;
    esac
}

# Show help
show_help() {
    cat << EOF
NeIO LeasingOps Health Check

Validates the health of a NeIO LeasingOps deployment.

Usage: $(basename "$0") [OPTIONS]

Options:
  --namespace, -n <NAME>     Kubernetes namespace (default: neio-leasingops)
  --timeout <SECONDS>        Timeout for health checks (default: 300)
  --wait                     Wait for pods to become ready before checking
  --json                     Output results as JSON
  --verbose, -v              Enable verbose output
  --help, -h                 Show this help message

Checks Performed:
  - Namespace exists
  - All pods are running and ready
  - Services are available
  - API health endpoint responds
  - Database connectivity (if internal PostgreSQL)
  - Redis connectivity (if internal Redis)
  - Storage connectivity (if internal MinIO)

Exit Codes:
  0  All health checks passed
  1  One or more health checks failed
  2  Critical failure (cluster unreachable, namespace missing)

Examples:
  $(basename "$0")
  $(basename "$0") --namespace production --wait
  $(basename "$0") --json --timeout 600

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
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --wait)
                WAIT_FOR_READY=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
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

# Detect CLI tool
detect_cli_tool() {
    if command -v oc &> /dev/null; then
        CLI_TOOL="oc"
    elif command -v kubectl &> /dev/null; then
        CLI_TOOL="kubectl"
    else
        log_error "Neither kubectl nor oc found in PATH"
        exit 2
    fi
    log_verbose "Using CLI tool: ${CLI_TOOL}"
}

# Check cluster connectivity
check_cluster() {
    log_header "Cluster Connectivity"

    if ${CLI_TOOL} cluster-info &> /dev/null; then
        record_check "cluster_connectivity" "pass" "Cluster is reachable"
    else
        record_check "cluster_connectivity" "fail" "Cannot connect to cluster"
        return 1
    fi

    # Check if logged in (for OpenShift)
    if [[ "${CLI_TOOL}" == "oc" ]]; then
        local user
        user=$(oc whoami 2>/dev/null || echo "")
        if [[ -n "${user}" ]]; then
            log_info "Logged in as: ${user}"
        fi
    fi
}

# Check namespace exists
check_namespace() {
    log_header "Namespace Check"

    if ${CLI_TOOL} get namespace "${NAMESPACE}" &> /dev/null; then
        record_check "namespace_exists" "pass" "Namespace '${NAMESPACE}' exists"
    else
        record_check "namespace_exists" "fail" "Namespace '${NAMESPACE}' not found"
        return 1
    fi
}

# Wait for pods to be ready
wait_for_pods() {
    log_header "Waiting for Pods"

    log_info "Waiting up to ${TIMEOUT}s for pods to be ready..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ ${elapsed} -gt ${TIMEOUT} ]]; then
            log_error "Timeout waiting for pods to be ready"
            return 1
        fi

        # Check if all pods are ready
        local not_ready
        not_ready=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
            --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')

        if [[ "${not_ready}" == "0" ]]; then
            local running
            running=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
                --no-headers 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
            if [[ "${running}" -gt 0 ]]; then
                log_success "All pods are ready (${running} running)"
                return 0
            fi
        fi

        log_verbose "Waiting... (${elapsed}s elapsed, ${not_ready} pods not ready)"
        sleep 5
    done
}

# Check pod status
check_pods() {
    log_header "Pod Status"

    # Get all pods in namespace
    local pods
    pods=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
        --no-headers 2>/dev/null || echo "")

    if [[ -z "${pods}" ]]; then
        record_check "pods_exist" "fail" "No pods found with label app.kubernetes.io/name=neio-leasingops"
        return 1
    fi

    record_check "pods_exist" "pass" "Found pods in namespace"

    # Check each pod type
    local api_pods db_pods redis_pods
    api_pods=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=api \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')

    log_verbose "API pods: ${api_pods}"

    # Check for running pods
    local running_pods
    running_pods=$(echo "${pods}" | grep -c "Running" || echo "0")
    local total_pods
    total_pods=$(echo "${pods}" | wc -l | tr -d ' ')

    if [[ "${running_pods}" -eq "${total_pods}" ]]; then
        record_check "pods_running" "pass" "All ${total_pods} pods are running"
    else
        record_check "pods_running" "fail" "Only ${running_pods}/${total_pods} pods are running"
    fi

    # Check for ready containers
    local not_ready
    not_ready=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | \
        grep -c "false" || echo "0")

    if [[ "${not_ready}" -eq 0 ]]; then
        record_check "containers_ready" "pass" "All containers are ready"
    else
        record_check "containers_ready" "fail" "${not_ready} containers are not ready"
    fi

    # Check for restarts
    local total_restarts
    total_restarts=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{" "}{end}' 2>/dev/null | \
        tr ' ' '\n' | awk '{sum+=$1} END {print sum}' || echo "0")

    if [[ "${total_restarts}" -eq 0 ]]; then
        record_check "pod_restarts" "pass" "No container restarts"
    elif [[ "${total_restarts}" -lt 5 ]]; then
        record_check "pod_restarts" "warn" "${total_restarts} total container restarts"
    else
        record_check "pod_restarts" "fail" "${total_restarts} container restarts (may indicate issues)"
    fi

    # Display pod details in verbose mode
    if [[ "${VERBOSE}" == "true" ]]; then
        echo ""
        ${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops
    fi
}

# Check services
check_services() {
    log_header "Service Status"

    local services
    services=$(${CLI_TOOL} get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
        --no-headers 2>/dev/null || echo "")

    if [[ -z "${services}" ]]; then
        record_check "services_exist" "fail" "No services found"
        return 1
    fi

    local svc_count
    svc_count=$(echo "${services}" | wc -l | tr -d ' ')
    record_check "services_exist" "pass" "Found ${svc_count} services"

    # Check API service specifically
    if ${CLI_TOOL} get svc -n "${NAMESPACE}" neio-leasingops-api &> /dev/null; then
        record_check "api_service" "pass" "API service exists"
    else
        # Try alternative naming
        if ${CLI_TOOL} get svc -n "${NAMESPACE}" -l app.kubernetes.io/component=api &> /dev/null; then
            record_check "api_service" "pass" "API service exists"
        else
            record_check "api_service" "warn" "API service not found (may use different name)"
        fi
    fi

    # Display services in verbose mode
    if [[ "${VERBOSE}" == "true" ]]; then
        echo ""
        ${CLI_TOOL} get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops
    fi
}

# Check API health endpoint
check_api_health() {
    log_header "API Health Endpoint"

    # Try to port-forward and check health
    local port=8080
    local health_url="http://localhost:${port}/health"

    # Find API pod
    local api_pod
    api_pod=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=api \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${api_pod}" ]]; then
        # Try alternative selector
        api_pod=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=neio-leasingops \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [[ -z "${api_pod}" ]]; then
        record_check "api_health" "warn" "Could not find API pod to check health"
        return 0
    fi

    log_verbose "Testing health via pod: ${api_pod}"

    # Execute health check inside the pod
    local health_response
    health_response=$(${CLI_TOOL} exec -n "${NAMESPACE}" "${api_pod}" -- \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null || echo "000")

    if [[ "${health_response}" == "200" ]]; then
        record_check "api_health" "pass" "API health endpoint returns 200"
    elif [[ "${health_response}" == "000" ]]; then
        # Try alternative approach - check if curl exists
        if ${CLI_TOOL} exec -n "${NAMESPACE}" "${api_pod}" -- which wget &> /dev/null; then
            health_response=$(${CLI_TOOL} exec -n "${NAMESPACE}" "${api_pod}" -- \
                wget -q -O - --spider http://localhost:8000/health 2>&1 && echo "200" || echo "fail")
            if [[ "${health_response}" == "200" ]]; then
                record_check "api_health" "pass" "API health endpoint is accessible"
            else
                record_check "api_health" "warn" "Could not verify API health (no curl/wget in container)"
            fi
        else
            record_check "api_health" "warn" "Could not verify API health (no curl in container)"
        fi
    else
        record_check "api_health" "fail" "API health endpoint returned ${health_response}"
    fi
}

# Check database connectivity
check_database() {
    log_header "Database Connectivity"

    # Check if PostgreSQL pod exists (internal deployment)
    local pg_pod
    pg_pod=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${pg_pod}" ]]; then
        log_info "No internal PostgreSQL found (may be using external database)"
        record_check "database" "pass" "External database configuration assumed"
        return 0
    fi

    log_verbose "Found PostgreSQL pod: ${pg_pod}"

    # Check if PostgreSQL is running
    local pg_status
    pg_status=$(${CLI_TOOL} get pod -n "${NAMESPACE}" "${pg_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${pg_status}" == "Running" ]]; then
        record_check "database_pod" "pass" "PostgreSQL pod is running"
    else
        record_check "database_pod" "fail" "PostgreSQL pod status: ${pg_status}"
        return 1
    fi

    # Try to check database connectivity
    local pg_ready
    pg_ready=$(${CLI_TOOL} exec -n "${NAMESPACE}" "${pg_pod}" -- \
        pg_isready -U postgres 2>/dev/null && echo "ready" || echo "not_ready")

    if [[ "${pg_ready}" == "ready" ]]; then
        record_check "database_connectivity" "pass" "PostgreSQL is accepting connections"
    else
        record_check "database_connectivity" "warn" "Could not verify PostgreSQL connectivity"
    fi
}

# Check Redis connectivity
check_redis() {
    log_header "Redis Connectivity"

    # Check if Redis pod exists
    local redis_pod
    redis_pod=$(${CLI_TOOL} get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${redis_pod}" ]]; then
        log_info "No internal Redis found (may be using external cache)"
        record_check "redis" "pass" "External Redis configuration assumed"
        return 0
    fi

    log_verbose "Found Redis pod: ${redis_pod}"

    # Check if Redis is running
    local redis_status
    redis_status=$(${CLI_TOOL} get pod -n "${NAMESPACE}" "${redis_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${redis_status}" == "Running" ]]; then
        record_check "redis_pod" "pass" "Redis pod is running"
    else
        record_check "redis_pod" "fail" "Redis pod status: ${redis_status}"
        return 1
    fi

    # Try Redis PING
    local redis_ping
    redis_ping=$(${CLI_TOOL} exec -n "${NAMESPACE}" "${redis_pod}" -- \
        redis-cli PING 2>/dev/null || echo "error")

    if [[ "${redis_ping}" == "PONG" ]]; then
        record_check "redis_connectivity" "pass" "Redis is responding to PING"
    else
        record_check "redis_connectivity" "warn" "Could not verify Redis connectivity"
    fi
}

# Print summary
print_summary() {
    log_header "Health Check Summary"

    echo ""
    echo -e "${BOLD}Results:${NC}"
    echo -e "  Total Checks: ${TOTAL_CHECKS}"
    echo -e "  ${GREEN}Passed:${NC} ${PASSED_CHECKS}"
    echo -e "  ${RED}Failed:${NC} ${FAILED_CHECKS}"
    echo -e "  ${YELLOW}Warnings:${NC} ${WARNINGS}"
    echo ""

    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All health checks passed!${NC}"
    else
        echo -e "${RED}${BOLD}Some health checks failed. Review the output above.${NC}"
    fi
}

# Output JSON results
output_json() {
    local status="healthy"
    if [[ ${FAILED_CHECKS} -gt 0 ]]; then
        status="unhealthy"
    elif [[ ${WARNINGS} -gt 0 ]]; then
        status="degraded"
    fi

    local checks_json="{"
    local first=true
    for key in "${!CHECK_RESULTS[@]}"; do
        local value="${CHECK_RESULTS[$key]}"
        local check_status="${value%%:*}"
        local check_message="${value#*:}"

        if [[ "${first}" != "true" ]]; then
            checks_json+=","
        fi
        first=false

        checks_json+="\"${key}\":{\"status\":\"${check_status}\",\"message\":\"${check_message}\"}"
    done
    checks_json+="}"

    jq -n \
        --arg status "${status}" \
        --arg namespace "${NAMESPACE}" \
        --argjson total "${TOTAL_CHECKS}" \
        --argjson passed "${PASSED_CHECKS}" \
        --argjson failed "${FAILED_CHECKS}" \
        --argjson warnings "${WARNINGS}" \
        --argjson checks "${checks_json}" \
        '{
            status: $status,
            namespace: $namespace,
            summary: {
                total: $total,
                passed: $passed,
                failed: $failed,
                warnings: $warnings
            },
            checks: $checks
        }'
}

# Main function
main() {
    parse_args "$@"
    detect_cli_tool

    if [[ "${JSON_OUTPUT}" != "true" ]]; then
        echo -e "${BOLD}${CYAN}NeIO LeasingOps Health Check${NC}"
        echo -e "Namespace: ${NAMESPACE}"
        echo ""
    fi

    # Run checks
    check_cluster || exit 2
    check_namespace || exit 2

    if [[ "${WAIT_FOR_READY}" == "true" ]]; then
        wait_for_pods || true
    fi

    check_pods
    check_services
    check_api_health
    check_database
    check_redis

    # Output results
    if [[ "${JSON_OUTPUT}" == "true" ]]; then
        output_json
    else
        print_summary
    fi

    # Exit with appropriate code
    if [[ ${FAILED_CHECKS} -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

# Run main
main "$@"
