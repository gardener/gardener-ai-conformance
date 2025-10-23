# Common Script Library (`scripts/common.sh`)

## Overview
This library provides standardized functions for Gardener AI conformance test scripts. It handles logging, resource management, cleanup, and common Kubernetes operations to make test scripts cleaner, more consistent, and easier to maintain.

## Core Features
- **Strict Mode:** All scripts use `set -euo pipefail` for safer execution
- **Standardized Logging:** Color-coded output with consistent formatting
- **Automatic Cleanup:** Trap-based cleanup system that ensures proper resource deletion
- **Smart Pre-cleanup:** Detects and cleans leftover resources before tests run
- **Test Lifecycle Management:** Structured initialization and finalization
- **Multi-Test Support:** Track results for tests with multiple sub-tests

## Usage Pattern

```bash
#!/bin/bash

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="My Conformance Test"
TEST_DESCRIPTION="Validates specific platform capability"
NAMESPACE="my-test-namespace"

# Optional: Register additional namespaces or resources for cleanup
ADDITIONAL_NAMESPACES=("controller-namespace")

# Initialize test (creates namespace, sets up logging and cleanup)
init_test

# Check prerequisites
check_kubernetes_access

# Your test logic here
log_step "Step 1: Deploy Test Resources"
# ... test code ...

# Finish test
finish_test_success "All requirements validated successfully"
```

## Function Reference

### Logging Functions

- **`log_step "Step Title"`** - Log a major test step with visual separation
- **`log_info "message"`** - Log informational message (ℹ️)
- **`log_pass "message"`** - Log success message (✅)
- **`log_fail "message"`** - Log failure and exit test (❌)
- **`log_fail_msg "message"`** - Log failure without exit (for cleanup)
- **`log_warn "message"`** - Log warning message (⚠️)
- **`log_raw "message"`** - Log without formatting (for summaries)

### Test Lifecycle Management

- **`init_test()`** - Initialize test (must be called first)
  - Auto-creates LOG_FILE at `test_result.log` in test directory
  - Creates primary namespace
  - Sets up cleanup trap handler
  - Performs pre-cleanup if leftover resources exist

- **`finish_test_success ["message"]`** - Complete test successfully
  - Logs success message
  - Exits with code 0
  - Cleanup runs automatically via trap

- **`finish_test_failure ["message"]`** - Complete test with failure
  - Logs failure message
  - Exits with code 1
  - Cleanup runs automatically via trap

### Cleanup Management

- **`add_cleanup_command "command"`** - Register command to run during cleanup
  - Commands execute in reverse order (LIFO)
  - Automatically run before namespace deletion
  - Example: `add_cleanup_command "helm uninstall my-release -n my-ns"`

- **`add_cleanup_namespace "namespace"`** - Register additional namespace for deletion

- **`add_cleanup_crd "crd-name"`** - Register CRD for deletion

- **`add_cleanup_cluster_resource "resource"`** - Register cluster resource
  - Example: `add_cleanup_cluster_resource "clusterrole my-role"`

### Namespace Management

- **`ensure_namespace "namespace"`** - Create namespace if not exists
  - Logs creation or existing status
  - Namespace automatically cleaned up via trap

- **`namespace_exists "namespace"`** - Check if namespace exists (returns 0/1)

### Pod Management

- **`wait_for_pod_ready "label-selector" "namespace" ["timeout"]`** - Wait for pod by label
  - Default timeout: 300s
  - Returns 0 on success, 1 on timeout
  - Example: `wait_for_pod_ready "app=myapp" "default" "180s"`

- **`wait_for_pod_ready_by_name "pod-name" "namespace" ["timeout"]`** - Wait for specific pod

- **`wait_for_pod_phase "pod-name" "namespace" "phase-pattern" ["timeout"]`** - Wait for phase
  - Supports regex: `"Succeeded|Failed"`
  - Example: `wait_for_pod_phase "job-pod" "default" "Succeeded|Failed" "300s"`

- **`get_pod_exit_code "pod-name" "namespace" ["container"]`** - Get pod exit code safely
  - Returns "unknown" if not available
  - Example: `EXIT_CODE=$(get_pod_exit_code "test-pod" "default")`

- **`get_pod_logs "pod-name" "namespace" ["container"]`** - Get pod logs safely
  - Returns "Failed to get logs" on error
  - Example: `LOGS=$(get_pod_logs "test-pod" "default")`

### Deployment Management

- **`wait_for_deployment "deployment" "namespace" ["timeout"]`** - Wait for deployment
  - Default timeout: 300s
  - Waits for condition=available

### Service & Networking

- **`service_exists "service" "namespace"`** - Check if service exists (returns 0/1)

- **`start_port_forward "resource" "namespace" "local-port" "remote-port"`** - Start port-forward
  - Returns PID for later cleanup
  - Automatically registers cleanup command
  - Example: `PF_PID=$(start_port_forward "svc/myapp" "default" 8080 8080)`

- **`stop_port_forward "pid"`** - Stop port-forward
  - Kills process and waits for termination

- **`test_metrics_endpoint "service" "namespace" "port" ["path"] ["local-port"]`** - Test metrics
  - Starts port-forward, tests endpoint, stops port-forward
  - Returns metrics content on success
  - Example: `METRICS=$(test_metrics_endpoint "svc/prometheus" "monitoring" 9090 "/metrics")`

- **`generate_http_traffic "url" ["count"] ["sleep-interval"]`** - Generate traffic
  - Default: 10 requests with 1s interval
  - Example: `generate_http_traffic "http://localhost:8080" 20 2`

### YAML Management

- **`apply_yaml "file-path" ["namespace"]`** - Apply YAML from file

- **`apply_yaml_stdin "yaml-content" ["namespace"]`** - Apply YAML from string

- **`apply_yaml_url "url" ["register-cleanup"]`** - Apply YAML from URL
  - Automatically registers cleanup if register-cleanup=true (default)
  - Example: `apply_yaml_url "https://example.com/manifest.yaml"`

### Helm Operations

- **`check_helm()`** - Verify Helm is installed (fails test if not)

- **`helm_add_repo "name" "url"`** - Add and update Helm repository

- **`helm_install "release" "chart" "namespace" ["extra-args"]`** - Install chart
  - Automatically registers cleanup command
  - Example: `helm_install "nginx" "bitnami/nginx" "default" "--set service.type=LoadBalancer"`

- **`helm_uninstall "release" "namespace"`** - Uninstall chart

### API & Resource Checks

- **`check_api_resource "resource" ["api-group"]`** - Check if API resource exists
  - Example: `check_api_resource "gateways" "gateway.networking.k8s.io"`

- **`check_api_version "api-version"`** - Check if API version exists
  - Example: `check_api_version "gateway.networking.k8s.io/v1"`

- **`check_crd_exists "crd-name"`** - Check if CRD exists (fails test if not)

### Prerequisite Checks

- **`check_kubernetes_access()`** - Verify kubectl and cluster access
  - Checks kubectl command exists
  - Verifies cluster connectivity
  - Logs results and fails test if issues found

- **`check_helm()`** - Verify Helm is installed

- **`check_gpu_nodes ["label"] ["value"]`** - Check for GPU nodes
  - Default: `node.kubernetes.io/instance-type=g4dn.xlarge`
  - Fails test if no GPU nodes found

### GPU-Specific Functions

- **`get_gpu_node_count ["label"]`** - Get count of GPU nodes
  - Default label: `worker.garden.sapcloud.io/group=worker-gpu`
  - Returns numeric count

- **`wait_for_gpu_node_count "expected" ["label"] ["timeout"]`** - Wait for node count
  - Default timeout: 600s
  - Logs progress every 15s
  - Returns 0 on success, 1 on timeout

### Multi-Test Tracking

For tests with multiple sub-tests (e.g., secure_accelerator_access):

- **`record_test_result "test-name" "true|false"`** - Record sub-test result
  - Example: `record_test_result "TEST 1: Isolation" "true"`

- **`all_tests_passed()`** - Check if all recorded tests passed (returns 0/1)

- **`print_test_results()`** - Print summary of all recorded test results

Example usage:
```bash
record_test_result "TEST 1: Feature A" "$TEST1_PASSED"
record_test_result "TEST 2: Feature B" "$TEST2_PASSED"

print_test_results

if all_tests_passed; then
    finish_test_success "All sub-tests passed"
else
    finish_test_failure "Some sub-tests failed"
fi
```

## Best Practices

1. **Always call `init_test()` first** - Sets up logging, cleanup, and creates namespace
2. **Use `log_step()` for major steps** - Provides clear visual separation
3. **Prefer `log_fail()` for fatal errors** - Automatically exits and triggers cleanup
4. **Register cleanup early** - Call `add_cleanup_command()` right after creating resources
5. **Use helper functions** - Reduces code duplication and improves consistency
6. **Check prerequisites** - Use `check_*` functions at start of tests
7. **Handle errors gracefully** - Most functions return proper exit codes
8. **Keep resources in namespace** - Simplifies cleanup
9. **Document test steps** - Use clear log messages for each step

## Cleanup Order

Cleanup executes in this order:
1. Custom cleanup commands (reverse order)
2. Primary namespace deletion
3. Additional namespaces deletion
4. CRD deletion
5. Cluster resource deletion

## Error Handling

- Functions return 0 on success, 1 on failure (where applicable)
- `log_fail()` exits immediately with code 1
- Cleanup always runs via trap (EXIT, INT, TERM signals)
- Pre-cleanup prevents conflicts with leftover resources
