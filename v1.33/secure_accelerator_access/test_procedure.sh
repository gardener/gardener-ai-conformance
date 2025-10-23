#!/bin/bash

# Secure Accelerator Access Conformance Test
# Tests that access to accelerators is properly isolated and mediated by Kubernetes

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Secure Accelerator Access Conformance Test"
TEST_DESCRIPTION="Validates that access to accelerators is properly isolated and mediated by the Kubernetes resource management framework"
NAMESPACE="secure-accelerator-access"

# Initialize test
init_test

# Check prerequisites
check_kubernetes_access

# Create test namespace
log_step "Setup: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created"

# Test 1: Pod without GPU request should not see GPUs
log_step "Test 1: Pod Without GPU Request"

log_info "Requirement: A pod that does not request GPU resources must not be able to access GPUs"
log_info "Creating pod without GPU resource request (but with affinity to guarantee GPU node placement)..."

cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: v1
kind: Pod
metadata:
  name: no-gpu-pod
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia.com/gpu.present
            operator: In
            values:
            - "true"
  containers:
  - name: test-container
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "Checking for GPU device files in /dev..."
        echo "Contents of /dev:"
        ls -la /dev/ | grep -i nvidia || echo "No nvidia devices found"
        echo ""

        # Check if any nvidia device files exist
        if ls /dev/nvidia* 2>/dev/null; then
          echo "ERROR: GPU devices are accessible - found /dev/nvidia* devices!"
          echo "This pod should NOT have access to GPU devices."
          exit 1
        else
          echo "SUCCESS: No GPU devices found in /dev/ - GPU access properly denied"
          exit 0
        fi
EOF

log_pass "Pod created, waiting for completion..."

# Wait for pod to complete
if ! wait_for_pod_phase "no-gpu-pod" "${NAMESPACE}" "Succeeded|Failed" "300s"; then
    log_warn "Pod did not complete within timeout"
fi

log_info "Pod logs:"
POD_LOGS=$(get_pod_logs "no-gpu-pod" "${NAMESPACE}")
echo "${POD_LOGS}" | sed 's/^/  /' | tee -a "${LOG_FILE}"

# Check if the test passed
POD_EXIT_CODE=$(get_pod_exit_code "no-gpu-pod" "${NAMESPACE}")
log_info "Pod exit code: ${POD_EXIT_CODE}"

if [[ "$POD_EXIT_CODE" == "0" ]]; then
    log_pass "TEST 1 PASSED: Pod without GPU request cannot access GPUs"
    record_test_result "TEST 1: Access Denial" "true"
else
    log_fail_msg "TEST 1 FAILED: Pod without GPU request was able to access GPUs or had unexpected behavior"
    record_test_result "TEST 1: Access Denial" "false"
fi

# Test 2: Pods with GPU requests should be isolated from each other
log_step "Test 2: GPU Isolation Between Pods"

log_info "Requirement: Pods with GPU allocations must be isolated - one pod cannot access another pod's GPU"
log_info "Creating deployment with 2 GPU pod replicas..."

# Create deployment with 2 replicas, each requesting 1 GPU
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-test-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gpu-test
  template:
    metadata:
      labels:
        app: gpu-test
    spec:
      containers:
      - name: cuda-container
        image: nvcr.io/nvidia/cuda:12.1.1-base-ubuntu22.04
        command: ["/bin/bash", "-c"]
        args:
          - |
            POD_NAME=\$(hostname)
            echo "\${POD_NAME}: Starting GPU isolation test..."
            echo "\${POD_NAME}: Verifying GPU device access..."
            echo "\${POD_NAME}: Checking for GPU device files in /dev/..."
            ls -la /dev/ | grep -i nvidia || echo "No nvidia devices found"
            echo ""

            if ls /dev/nvidia* 2>/dev/null; then
              echo "\${POD_NAME}: SUCCESS - GPU devices ARE accessible (/dev/nvidia* found)"
            else
              echo "\${POD_NAME}: ERROR - GPU devices NOT accessible despite requesting GPU!"
              exit 1
            fi

            echo ""
            echo "\${POD_NAME}: Collecting GPU information..."
            nvidia-smi -L
            nvidia-smi --query-gpu=uuid --format=csv,noheader > /tmp/my_gpu_uuid.txt
            MY_GPU_UUID=\$(cat /tmp/my_gpu_uuid.txt)
            echo "\${POD_NAME}: My GPU UUID: \${MY_GPU_UUID}"

            echo "\${POD_NAME}: Testing if I can see multiple GPUs (should only see 1)..."
            GPU_COUNT=\$(nvidia-smi -L | wc -l)
            echo "\${POD_NAME}: Number of GPUs visible: \${GPU_COUNT}"
            if [ "\${GPU_COUNT}" -ne 1 ]; then
              echo "\${POD_NAME}: FAILURE - Can see \${GPU_COUNT} GPUs instead of 1"
              exit 1
            fi
            echo "\${POD_NAME}: SUCCESS - Can only see my allocated GPU"

            echo "\${POD_NAME}: Testing device isolation - checking if unauthorized GPU devices are accessible..."
            for i in 1 2 3 4 5 6 7; do
              if [ -c "/dev/nvidia\${i}" ]; then
                echo "\${POD_NAME}: FAILURE - Unauthorized access to /dev/nvidia\${i} detected!"
                exit 1
              fi
            done
            echo "\${POD_NAME}: SUCCESS - Cannot access unauthorized GPU devices"

            echo "\${POD_NAME}: All isolation tests completed successfully"
            echo "\${POD_NAME}: Keeping pod running for test observation..."

            # Keep container running indefinitely
            while true; do
              sleep 3600
            done
        resources:
          requests:
            nvidia.com/gpu: 1
          limits:
            nvidia.com/gpu: 1
EOF

log_pass "GPU test deployment created"

log_info "Waiting for deployment to be ready (may trigger cluster autoscaling)..."
kubectl rollout status deployment/gpu-test-deployment -n "${NAMESPACE}" --timeout=900s 2>&1 | tee -a "${LOG_FILE}" || true

log_info "Checking deployment status..."
kubectl get deployment gpu-test-deployment -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
kubectl get pods -n "${NAMESPACE}" -l app=gpu-test 2>&1 | tee -a "${LOG_FILE}"

# Get the pod names
POD_NAMES=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-test -o jsonpath='{.items[*].metadata.name}')
POD_ARRAY=($POD_NAMES)

if [ "${#POD_ARRAY[@]}" -lt 2 ]; then
    log_fail_msg "Expected 2 pods but found ${#POD_ARRAY[@]}"
    log_fail_msg "Deployment may not have scaled properly"
    record_test_result "TEST 2: GPU Isolation" "false"
else
    POD1_NAME="${POD_ARRAY[0]}"
    POD2_NAME="${POD_ARRAY[1]}"

    log_info "Found pods: ${POD1_NAME} and ${POD2_NAME}"

    # Wait a bit to ensure logs are generated
    log_info "Waiting for pods to complete initial tests..."
    sleep 5

    # Get logs from both pods
    log_info "Pod ${POD1_NAME} logs:"
    POD1_LOGS=$(get_pod_logs "${POD1_NAME}" "${NAMESPACE}")
    echo "${POD1_LOGS}" | sed 's/^/  /' | tee -a "${LOG_FILE}"

    log_info "Pod ${POD2_NAME} logs:"
    POD2_LOGS=$(get_pod_logs "${POD2_NAME}" "${NAMESPACE}")
    echo "${POD2_LOGS}" | sed 's/^/  /' | tee -a "${LOG_FILE}"

    # Extract GPU UUIDs from pod logs
    POD1_UUID=$(echo "${POD1_LOGS}" | grep "My GPU UUID:" | head -1 | cut -d: -f3 | tr -d ' ')
    POD2_UUID=$(echo "${POD2_LOGS}" | grep "My GPU UUID:" | head -1 | cut -d: -f3 | tr -d ' ')

    log_info "GPU UUID Analysis:"
    log_info "  Pod ${POD1_NAME} GPU UUID: ${POD1_UUID}"
    log_info "  Pod ${POD2_NAME} GPU UUID: ${POD2_UUID}"

    # Check if cluster has multiple GPUs available
    TOTAL_GPU_CAPACITY=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' | tr ' ' '+' | bc 2>/dev/null || echo "unknown")

    # Check for errors in pod logs
    POD1_HAS_ERROR=$(echo "${POD1_LOGS}" | grep -i "FAILURE\|ERROR" || echo "")
    POD2_HAS_ERROR=$(echo "${POD2_LOGS}" | grep -i "FAILURE\|ERROR" || echo "")

    # Evaluate test results
    if [[ -z "$POD1_HAS_ERROR" && -z "$POD2_HAS_ERROR" ]]; then
        # Both pods ran their tests successfully, now check GPU isolation
        if [[ -n "$POD1_UUID" && -n "$POD2_UUID" ]]; then
            if [[ "$POD1_UUID" == "$POD2_UUID" ]]; then
                log_warn "Both pods report the same GPU UUID: ${POD1_UUID}"
                log_info "Total GPU capacity in cluster: ${TOTAL_GPU_CAPACITY}"
                log_fail_msg "TEST 2 FAILED: Cannot validate cross-pod GPU isolation requirement"
                log_fail_msg "  - Both pods allocated the SAME GPU (UUID: ${POD1_UUID})"
                log_fail_msg "  - Total GPU capacity in cluster: ${TOTAL_GPU_CAPACITY}"
                log_fail_msg "  - Requirement states: 'Execute a command in one Pod to attempt to access the other Pod's accelerator'"
                log_fail_msg "  - This requires pods to be allocated DIFFERENT GPUs"
                log_fail_msg ""
                log_fail_msg "What was validated (insufficient for requirement):"
                log_fail_msg "  ✓ Each pod can only see 1 GPU via nvidia-smi"
                log_fail_msg "  ✓ Device files nvidia1-nvidia7 not accessible"
                log_fail_msg "  ✓ Time-slicing isolation (if enabled)"
                log_fail_msg ""
                log_fail_msg "What was NOT validated (required by spec):"
                log_fail_msg "  ✗ Pod 1 attempting to access Pod 2's different GPU"
                log_fail_msg "  ✗ Cross-pod physical GPU isolation"
                log_fail_msg ""
                log_fail_msg "To properly test this requirement, the cluster needs multiple GPUs"
                log_fail_msg "so that each pod can be allocated a different GPU."
                record_test_result "TEST 2: GPU Isolation" "false"
            else
                log_pass "SUCCESS: Pods have different GPU UUIDs - proper hardware isolation confirmed"
                log_info "  Pod ${POD1_NAME} GPU: ${POD1_UUID}"
                log_info "  Pod ${POD2_NAME} GPU: ${POD2_UUID}"
                log_pass "TEST 2 PASSED: GPU isolation is working correctly"
                log_pass "  - Pods allocated different GPUs"
                log_pass "  - Each pod can only see exactly 1 GPU"
                log_pass "  - Pods cannot access unauthorized GPU device files"
                log_pass "  - Container runtime properly mediates GPU access"
                record_test_result "TEST 2: GPU Isolation" "true"
            fi
        else
            log_fail_msg "TEST 2 FAILED: Could not extract GPU UUIDs from pod logs"
            record_test_result "TEST 2: GPU Isolation" "false"
        fi
    else
        log_fail_msg "TEST 2 FAILED: GPU isolation tests reported errors in one or both pods"
        if [[ -n "$POD1_HAS_ERROR" ]]; then
            log_fail_msg "  - Pod ${POD1_NAME} reported errors"
        fi
        if [[ -n "$POD2_HAS_ERROR" ]]; then
            log_fail_msg "  - Pod ${POD2_NAME} reported errors"
        fi
        record_test_result "TEST 2: GPU Isolation" "false"
    fi
fi

# Final summary
log_step "Test Summary"

print_test_results

log_raw "CONFORMANCE RESULT:"
if all_tests_passed; then
    log_raw "✅ Platform MEETS the secure accelerator access requirement."
    log_raw ""
    log_raw "Validated capabilities:"
    log_raw "  ✓ Pods without GPU requests cannot access GPU devices"
    log_raw "  ✓ Pods with GPU requests are properly isolated from each other"
    log_raw "  ✓ Container runtime mediates all GPU device access"
    log_raw "  ✓ Kubernetes resource management framework (NVIDIA device plugin) enforces allocation"
    log_raw ""
    log_raw "Access to accelerators is properly isolated and mediated by the"
    log_raw "Kubernetes resource management framework and container runtime,"
    log_raw "preventing unauthorized access or interference between workloads."
    finish_test_success "All secure accelerator access requirements validated successfully"
else
    log_raw "❌ Platform does NOT meet the secure accelerator access requirement."
    log_raw ""
    log_raw "Failed validations indicate that GPU access isolation is not properly"
    log_raw "implemented, which could allow unauthorized access or interference"
    log_raw "between workloads."
    finish_test_failure "Some secure accelerator access tests failed - GPU isolation not properly enforced"
fi
