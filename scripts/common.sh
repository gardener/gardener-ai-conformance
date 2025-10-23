#!/bin/bash
#
# ====================================================================================
# Common Script Library for Gardener AI Conformance Tests
#
# This library provides a set of common functions and constants to standardize
# the test procedures, making them cleaner, more consistent, and easier to maintain.
#
# Usage in test scripts:
#   #!/bin/bash
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../scripts/common.sh"
#
#   # Set test-specific variables
#   TEST_NAME="My Test"
#   TEST_DESCRIPTION="Description of what this test does"
#   NAMESPACE="my-test-namespace"
#
#   # Initialize test
#   init_test
#
#   # Your test logic here
#   log_step "Step 1: Do something"
#   # ...
#
#   # Finish test
#   finish_test_success
# ====================================================================================

# --- Strict Mode ---
set -euo pipefail

# --- Constants: Colors and Symbols ---
readonly C_BLUE='\033[0;34m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_NC='\033[0m' # No Color

readonly S_PASS="✅"
readonly S_FAIL="❌"
readonly S_WARN="⚠️"
readonly S_INFO="ℹ️"
readonly S_STEP="🔹"
readonly S_SUCCESS="🎉"

# --- Global Variables ---
# These should be set by the test script before calling init_test:
# - TEST_NAME: Name of the test
# - TEST_DESCRIPTION: Description of what the test does
# - NAMESPACE: Primary namespace for the test
# - LOG_FILE: Will be auto-set to test_result.log in the script's directory

# Additional optional variables:
# - ADDITIONAL_NAMESPACES: Array of additional namespaces to clean up
# - CLEANUP_CRDS: Array of CRD names to delete during cleanup
# - CLEANUP_CLUSTER_RESOURCES: Array of cluster resources to delete (e.g., "clusterrole my-role")

declare -a CLEANUP_CMDS=()
declare -a ADDITIONAL_NAMESPACES=()
declare -a CLEANUP_CRDS=()
declare -a CLEANUP_CLUSTER_RESOURCES=()
CLEANUP_EXECUTED=false

# --- Logging Functions ---

# Internal log function - always use this for output
_log() {
    local message="$1"
    local no_color="${2:-false}"

    if [[ "$no_color" == "true" ]]; then
        # Strip ANSI color codes for file logging
        echo -e "${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
        echo -e "${message}"
    else
        echo -e "${message}" | tee -a "${LOG_FILE}"
    fi
}

# Log a test step header
log_step() {
    _log ""
    _log "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}" true
    _log "${C_BLUE}${S_STEP} $1${C_NC}" true
    _log "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}" true
}

# Log informational message
log_info() {
    _log "${S_INFO} $1"
}

# Log success message
log_pass() {
    _log "${C_GREEN}${S_PASS} $1${C_NC}" true
}

# Log failure message (does NOT exit)
log_fail_msg() {
    _log "${C_RED}${S_FAIL} $1${C_NC}" true
}

# Log failure and exit
log_fail() {
    log_fail_msg "$1"
    exit 1
}

# Log warning message
log_warn() {
    _log "${C_YELLOW}${S_WARN} $1${C_NC}" true
}

# Log command execution
log_command() {
    local cmd="$1"
    _log "${C_CYAN}▶ Running: ${cmd}${C_NC}" true
}

# Log raw output (no prefix)
log_raw() {
    _log "$1"
}

# --- Test Initialization ---

# Initialize test - must be called at the start of each test script
init_test() {
    # Auto-detect LOG_FILE if not set
    if [[ -z "${LOG_FILE:-}" ]]; then
        LOG_FILE="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/test_result.log"
    fi

    # Clear the log file
    : > "${LOG_FILE}"

    # Print test header
    _log "════════════════════════════════════════════════════════════════"
    _log "  ${TEST_NAME}"
    _log "════════════════════════════════════════════════════════════════"
    _log ""
    _log "Test Started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    _log "Description: ${TEST_DESCRIPTION}"
    _log "Primary Namespace: ${NAMESPACE}"
    _log ""

    # Display REQUIREMENT.md content if it exists
    local test_dir
    test_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local requirement_file="${test_dir}/REQUIREMENT.md"

    if [[ -f "$requirement_file" ]]; then
        log_step "Requirement Specification"
        _log ""
        # Read and log the requirement file content
        while IFS= read -r line; do
            _log "$line"
        done < "$requirement_file"
        _log ""
    else
        log_warn "REQUIREMENT.md not found at: $requirement_file"
    fi

    # Set up trap for cleanup
    trap '_cleanup_handler' EXIT INT TERM

    # Perform pre-test cleanup check
    perform_pre_cleanup
}

# Perform pre-test cleanup if leftover resources exist
perform_pre_cleanup() {
    log_step "Pre-Test Cleanup Check"

    local needs_cleanup=false

    # Check primary namespace
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_warn "Found leftover namespace: ${NAMESPACE}"
        needs_cleanup=true
    fi

    # Check additional namespaces
    for ns in "${ADDITIONAL_NAMESPACES[@]}"; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            log_warn "Found leftover namespace: ${ns}"
            needs_cleanup=true
        fi
    done

    if [[ "$needs_cleanup" == "true" ]]; then
        log_info "Cleaning up leftover resources from previous test run..."
        _perform_cleanup_operations
        log_pass "Pre-test cleanup completed"
        log_info "Waiting 5 seconds before starting test..."
        sleep 5
    else
        log_pass "No leftover resources found"
    fi
}

# Internal cleanup handler (called by trap)
_cleanup_handler() {
    local exit_code=$?

    # Prevent double cleanup
    if [[ "$CLEANUP_EXECUTED" == "true" ]]; then
        return 0
    fi
    CLEANUP_EXECUTED=true

    log_step "Final Cleanup"

    if [[ $exit_code -ne 0 ]]; then
        log_warn "Test failed with exit code ${exit_code}. Cleaning up..."
    else
        log_info "Test completed. Cleaning up..."
    fi

    _perform_cleanup_operations

    log_pass "Cleanup completed"

    exit $exit_code
}

# Perform actual cleanup operations (used by both pre-cleanup and final cleanup)
_perform_cleanup_operations() {
    # Execute custom cleanup commands first (in reverse order)
    for ((i=${#CLEANUP_CMDS[@]}-1; i>=0; i--)); do
        log_info "Executing: ${CLEANUP_CMDS[i]}"
        eval "${CLEANUP_CMDS[i]}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
    done

    # Delete resources in primary namespace
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Deleting namespace: ${NAMESPACE}"
        kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --timeout=120s 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
        wait_for_namespace_deletion "${NAMESPACE}"
    fi

    # Delete additional namespaces
    for ns in "${ADDITIONAL_NAMESPACES[@]}"; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            log_info "Deleting namespace: ${ns}"
            kubectl delete namespace "${ns}" --ignore-not-found=true --timeout=120s 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
            wait_for_namespace_deletion "${ns}"
        fi
    done

    # Delete CRDs
    for crd in "${CLEANUP_CRDS[@]}"; do
        log_info "Deleting CRD: ${crd}"
        kubectl delete crd "${crd}" --ignore-not-found=true 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
    done

    # Delete cluster-level resources
    for resource in "${CLEANUP_CLUSTER_RESOURCES[@]}"; do
        log_info "Deleting cluster resource: ${resource}"
        kubectl delete ${resource} --ignore-not-found=true 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
    done
}

# Wait for namespace to be fully deleted
wait_for_namespace_deletion() {
    local ns="$1"
    local timeout=60
    local elapsed=0

    while kubectl get namespace "${ns}" &>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if kubectl get namespace "${ns}" &>/dev/null; then
        log_warn "Namespace ${ns} still exists after ${timeout}s"
    fi
}

# Add a custom cleanup command (executed before namespace deletion)
add_cleanup_command() {
    CLEANUP_CMDS+=("$1")
}

# Register additional namespace for cleanup
add_cleanup_namespace() {
    ADDITIONAL_NAMESPACES+=("$1")
}

# Register CRD for cleanup
add_cleanup_crd() {
    CLEANUP_CRDS+=("$1")
}

# Register cluster resource for cleanup (e.g., "clusterrole my-role")
add_cleanup_cluster_resource() {
    CLEANUP_CLUSTER_RESOURCES+=("$1")
}

# --- Test Completion ---

# Finish test with success
finish_test_success() {
    local summary="${1:-All tests passed successfully}"

    log_step "Test Result"
    log_pass "${summary}"
    _log ""
    _log "${C_GREEN}${S_SUCCESS} Test completed successfully!${C_NC}" true
    _log ""
    exit 0
}

# Finish test with failure
finish_test_failure() {
    local summary="${1:-Test failed}"

    log_step "Test Result"
    log_fail_msg "${summary}"
    _log ""
    _log "${C_RED}${S_FAIL} Test failed!${C_NC}" true
    _log ""
    exit 1
}

# --- Kubernetes Helper Functions ---

# Check if a namespace exists
namespace_exists() {
    local ns="$1"
    kubectl get namespace "${ns}" &>/dev/null
}

# Create namespace if it doesn't exist
ensure_namespace() {
    local ns="$1"

    if ! namespace_exists "${ns}"; then
        log_info "Creating namespace: ${ns}"
        kubectl create namespace "${ns}"
        log_pass "Namespace created: ${ns}"
    else
        log_info "Namespace already exists: ${ns}"
    fi
}

# Wait for pod to be ready (using label selector)
wait_for_pod_ready() {
    local pod_selector="$1"
    local namespace="$2"
    local timeout="${3:-300s}"

    log_info "Waiting for pod (${pod_selector}) in namespace ${namespace} to be ready (timeout: ${timeout})..."

    if kubectl wait --for=condition=ready pod -l "${pod_selector}" -n "${namespace}" --timeout="${timeout}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"; then
        log_pass "Pod is ready"
        return 0
    else
        log_warn "Pod did not become ready within ${timeout}"
        return 1
    fi
}

# Wait for specific pod name to be ready
wait_for_pod_ready_by_name() {
    local pod_name="$1"
    local namespace="$2"
    local timeout="${3:-300s}"

    log_info "Waiting for pod ${pod_name} in namespace ${namespace} to be ready (timeout: ${timeout})..."

    if kubectl wait --for=condition=ready pod/"${pod_name}" -n "${namespace}" --timeout="${timeout}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"; then
        log_pass "Pod is ready"
        return 0
    else
        log_warn "Pod did not become ready within ${timeout}"
        return 1
    fi
}

# Wait for pod to reach specific phase(s) - supports regex patterns like "Succeeded|Failed"
wait_for_pod_phase() {
    local pod_name="$1"
    local namespace="$2"
    local phase_pattern="$3"  # e.g., "Succeeded|Failed"
    local timeout="${4:-300s}"

    log_info "Waiting for pod ${pod_name} to reach phase: ${phase_pattern} (timeout: ${timeout})..."

    local timeout_seconds
    timeout_seconds=$(echo "${timeout}" | sed 's/s$//')
    local elapsed=0
    local check_interval=5

    while [[ $elapsed -lt $timeout_seconds ]]; do
        local current_phase
        current_phase=$(kubectl get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if echo "${current_phase}" | grep -qE "${phase_pattern}"; then
            log_pass "Pod reached phase: ${current_phase}"
            return 0
        fi

        sleep ${check_interval}
        elapsed=$((elapsed + check_interval))
    done

    log_warn "Pod did not reach expected phase within ${timeout}"
    return 1
}

# Alias for backwards compatibility
wait_for_pod() {
    wait_for_pod_ready "$@"
}

# Wait for deployment to be available
wait_for_deployment() {
    local deployment="$1"
    local namespace="$2"
    local timeout="${3:-300s}"

    log_info "Waiting for deployment ${deployment} in namespace ${namespace} to be available (timeout: ${timeout})..."

    if kubectl wait --for=condition=available deployment/"${deployment}" -n "${namespace}" --timeout="${timeout}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"; then
        log_pass "Deployment is available"
        return 0
    else
        log_warn "Deployment did not become available within ${timeout}"
        return 1
    fi
}

# Apply YAML from file
apply_yaml() {
    local yaml_file="$1"
    local namespace="${2:-}"

    log_info "Applying YAML: ${yaml_file}"

    if [[ -n "$namespace" ]]; then
        kubectl apply -f "${yaml_file}" -n "${namespace}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    else
        kubectl apply -f "${yaml_file}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    fi
}

# Apply YAML from stdin
apply_yaml_stdin() {
    local yaml_content="$1"
    local namespace="${2:-}"

    if [[ -n "$namespace" ]]; then
        echo "${yaml_content}" | kubectl apply -f - -n "${namespace}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    else
        echo "${yaml_content}" | kubectl apply -f - 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    fi
}

# Port-forward with automatic cleanup registration
start_port_forward() {
    local resource="$1"
    local namespace="$2"
    local local_port="$3"
    local remote_port="$4"

    log_info "Starting port-forward: ${resource} ${local_port}:${remote_port} in namespace ${namespace}" >&2

    kubectl port-forward -n "${namespace}" "${resource}" "${local_port}:${remote_port}" &>/dev/null &
    local pf_pid=$!

    # Register cleanup
    add_cleanup_command "kill ${pf_pid} 2>/dev/null || true; wait ${pf_pid} 2>/dev/null || true"

    # Give port-forward time to establish
    sleep 5

    echo "${pf_pid}"
}

# Stop port-forward
stop_port_forward() {
    local pf_pid="$1"

    log_info "Stopping port-forward (PID: ${pf_pid})" >&2
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
}

# Test metrics endpoint via curl with port-forward
test_metrics_endpoint() {
    local service="$1"
    local namespace="$2"
    local port="$3"
    local path="${4:-/metrics}"
    local local_port="${5:-$port}"

    log_info "Testing metrics endpoint: ${service}:${port}${path}"

    # Start port-forward
    local pf_pid
    pf_pid=$(start_port_forward "${service}" "${namespace}" "${local_port}" "${port}")

    # Test endpoint
    local metrics_output
    local curl_exit_code=0
    metrics_output=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://localhost:${local_port}${path}" 2>&1) || curl_exit_code=$?

    # Stop port-forward
    stop_port_forward "${pf_pid}"

    # Check results
    if [[ $curl_exit_code -ne 0 ]]; then
        log_fail_msg "Cannot access metrics endpoint. curl failed with exit code: ${curl_exit_code}"
        return 1
    fi

    # Extract HTTP code and content
    local http_code
    http_code=$(echo "$metrics_output" | grep "HTTP_CODE:" | cut -d':' -f2)
    local metrics_content
    metrics_content=$(echo "$metrics_output" | grep -v "HTTP_CODE:")

    if [[ "$http_code" != "200" ]]; then
        log_fail_msg "Metrics endpoint returned HTTP ${http_code} instead of 200"
        return 1
    fi

    if [[ -z "$metrics_content" ]]; then
        log_fail_msg "Metrics endpoint returned empty response"
        return 1
    fi

    log_pass "Metrics endpoint accessible (HTTP 200)"

    # Return metrics content for further processing
    echo "$metrics_content"
    return 0
}

# --- Helm Helper Functions ---

# Add Helm repository
helm_add_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log_info "Adding Helm repository: ${repo_name}"
    helm repo add "${repo_name}" "${repo_url}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
    helm repo update 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
}

# Install Helm chart with automatic cleanup registration
helm_install() {
    local release_name="$1"
    local chart="$2"
    local namespace="$3"
    shift 3
    local extra_args="$*"

    log_info "Installing Helm chart: ${release_name} (${chart}) in namespace ${namespace}"

    # Register cleanup first
    add_cleanup_command "helm uninstall ${release_name} -n ${namespace} --wait 2>&1 | sed 's/^/  /' >> ${LOG_FILE} || true"

    # Install with eval to properly expand extra_args
    if [[ -n "$extra_args" ]]; then
        eval "helm install ${release_name} ${chart} -n ${namespace} ${extra_args}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    else
        helm install "${release_name}" "${chart}" -n "${namespace}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"
    fi
}

# Uninstall Helm chart
helm_uninstall() {
    local release_name="$1"
    local namespace="$2"

    log_info "Uninstalling Helm chart: ${release_name} from namespace ${namespace}"
    helm uninstall "${release_name}" -n "${namespace}" --wait 2>&1 | sed 's/^/  /' >> "${LOG_FILE}" || true
}

# --- Prerequisite Checks ---

# Check kubectl is available and cluster is accessible
check_kubernetes_access() {
    log_step "Checking Kubernetes Access"

    if ! command -v kubectl &>/dev/null; then
        log_fail "kubectl command not found"
    fi
    log_pass "kubectl is available"

    if ! kubectl cluster-info &>/dev/null; then
        log_fail "Cannot connect to Kubernetes cluster"
    fi
    log_pass "Connected to Kubernetes cluster"
}

# Check for GPU nodes with specific label
check_gpu_nodes() {
    local label="${1:-node.kubernetes.io/instance-type}"
    local value="${2:-g4dn.xlarge}"

    log_info "Checking for GPU nodes (${label}=${value})..."

    local gpu_nodes
    gpu_nodes=$(kubectl get nodes -l "${label}=${value}" -o name 2>/dev/null || true)

    if [[ -z "$gpu_nodes" ]]; then
        log_fail "No GPU nodes found with label ${label}=${value}"
    fi

    local count
    count=$(echo "${gpu_nodes}" | wc -l | tr -d ' ')
    log_pass "Found ${count} GPU node(s)"
}

# Check Helm is available
check_helm() {
    if ! command -v helm &>/dev/null; then
        log_fail "helm command not found"
    fi
    log_pass "helm is available"
}

# Check for specific CRD
check_crd_exists() {
    local crd_name="$1"

    log_info "Checking for CRD: ${crd_name}..."

    if kubectl get crd "${crd_name}" &>/dev/null; then
        log_pass "CRD exists: ${crd_name}"
        return 0
    else
        log_fail "CRD not found: ${crd_name}"
        return 1
    fi
}

# --- Additional Kubernetes Helper Functions ---

# Get pod exit code safely
get_pod_exit_code() {
    local pod_name="$1"
    local namespace="$2"
    local container="${3:-}" # Optional: specific container name

    local exit_code
    if [[ -n "$container" ]]; then
        exit_code=$(kubectl get pod "${pod_name}" -n "${namespace}" -o jsonpath="{.status.containerStatuses[?(@.name=='${container}')].state.terminated.exitCode}" 2>/dev/null || echo "unknown")
    else
        exit_code=$(kubectl get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "unknown")
    fi
    echo "${exit_code}"
}

# Get pod logs safely
get_pod_logs() {
    local pod_name="$1"
    local namespace="$2"
    local container="${3:-}" # Optional: specific container name

    if [[ -n "$container" ]]; then
        kubectl logs "${pod_name}" -n "${namespace}" -c "${container}" 2>&1 || echo "Failed to get logs"
    else
        kubectl logs "${pod_name}" -n "${namespace}" 2>&1 || echo "Failed to get logs"
    fi
}

# Check if API resource exists
check_api_resource() {
    local resource="$1"
    local api_group="${2:-}"

    if [[ -n "$api_group" ]]; then
        kubectl api-resources --api-group="${api_group}" 2>/dev/null | awk -v res="${resource}" '$1 == res {found=1} END {exit !found}'
    else
        kubectl api-resources 2>/dev/null | awk -v res="${resource}" '$1 == res {found=1} END {exit !found}'
    fi
}

# Check if API version exists
check_api_version() {
    local api_version="$1"
    kubectl api-versions 2>/dev/null | grep -q "^${api_version}$"
}

# Check if service exists
service_exists() {
    local service="$1"
    local namespace="$2"
    kubectl get service "${service}" -n "${namespace}" &>/dev/null
}

# Apply YAML from URL with automatic cleanup registration
apply_yaml_url() {
    local url="$1"
    local register_cleanup="${2:-true}" # Default: register cleanup

    log_info "Applying YAML from URL: ${url}"

    if kubectl apply -f "${url}" 2>&1 | sed 's/^/  /' >> "${LOG_FILE}"; then
        if [[ "$register_cleanup" == "true" ]]; then
            add_cleanup_command "kubectl delete -f ${url} --ignore-not-found=true 2>&1 | sed 's/^/  /' >> ${LOG_FILE} || true"
        fi
        return 0
    else
        return 1
    fi
}

# Generate HTTP traffic to a service (useful for metrics generation)
generate_http_traffic() {
    local url="$1"
    local count="${2:-10}"
    local sleep_interval="${3:-1}"

    log_info "Generating ${count} HTTP requests to ${url}..."

    for i in $(seq 1 "$count"); do
        curl -s "${url}" >/dev/null 2>&1 || true
        sleep "$sleep_interval"
    done

    log_pass "Generated ${count} requests"
}

# --- GPU-Specific Helper Functions ---

# Get count of GPU nodes matching a label
get_gpu_node_count() {
    local label="${1:-worker.garden.sapcloud.io/group=worker-gpu}"
    kubectl get nodes -l "${label}" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Wait for specific GPU node count
wait_for_gpu_node_count() {
    local expected="$1"
    local label="${2:-worker.garden.sapcloud.io/group=worker-gpu}"
    local timeout="${3:-600}"
    local start_time
    start_time=$(date +%s)

    log_info "Waiting for GPU node count to reach ${expected} (timeout: ${timeout}s)"

    while true; do
        local current
        current=$(get_gpu_node_count "${label}")
        local elapsed
        elapsed=$(($(date +%s) - start_time))

        if [[ "$current" -eq "$expected" ]]; then
            log_pass "GPU node count reached ${expected} after ${elapsed}s"
            return 0
        fi

        if [[ "$elapsed" -ge "$timeout" ]]; then
            log_fail_msg "Timeout waiting for node count ${expected} (current: ${current}, elapsed: ${elapsed}s)"
            return 1
        fi

        log_info "Current: ${current}, Expected: ${expected}, Elapsed: ${elapsed}s"
        sleep 15
    done
}

# --- YAML Generation Helper Functions ---

# Apply inline YAML with proper logging
apply_inline_yaml() {
    local namespace="$1"
    local yaml_content="$2"

    echo "${yaml_content}" | kubectl apply -n "${namespace}" -f - 2>&1 | tee -a "${LOG_FILE}"
}

# Apply inline YAML to cluster (no namespace)
apply_inline_yaml_cluster() {
    local yaml_content="$1"

    echo "${yaml_content}" | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
}

# --- Test Result Tracking ---

# Track individual test results (useful for multi-part tests)
declare -A TEST_RESULTS=()

# Record a test result
record_test_result() {
    local test_name="$1"
    local passed="$2" # true or false

    TEST_RESULTS["${test_name}"]="${passed}"
}

# Check if all recorded tests passed
all_tests_passed() {
    for test_name in "${!TEST_RESULTS[@]}"; do
        if [[ "${TEST_RESULTS[$test_name]}" != "true" ]]; then
            return 1
        fi
    done
    return 0
}

# Print test results summary
print_test_results() {
    log_raw ""
    log_raw "Test Results Summary:"
    for test_name in "${!TEST_RESULTS[@]}"; do
        if [[ "${TEST_RESULTS[$test_name]}" == "true" ]]; then
            log_raw "✅ ${test_name}"
        else
            log_raw "❌ ${test_name}"
        fi
    done
    log_raw ""
}

# --- Finalization ---
# Note: Do not log here as LOG_FILE is not yet initialized
# The library is ready for use once sourced
