#!/bin/bash

# Robust Controller Conformance Test
# Tests that complex AI operators with CRDs can be installed and function reliably

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Robust Controller Conformance Test"
TEST_DESCRIPTION="Validates that complex AI operators (KubeRay) can be installed and function reliably"
NAMESPACE="robust-controller"
OPERATOR_NAMESPACE="kuberay-operator"

# Register additional namespace for cleanup
ADDITIONAL_NAMESPACES=("${OPERATOR_NAMESPACE}")

# Initialize test
init_test

# Check prerequisites
check_kubernetes_access
check_helm

# Step 1: Create test namespace
log_step "Step 1: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created: ${NAMESPACE}"

# Step 2: Create operator namespace
log_step "Step 2: Create Operator Namespace"
ensure_namespace "${OPERATOR_NAMESPACE}"
log_pass "Operator namespace created: ${OPERATOR_NAMESPACE}"

# Step 3: Install KubeRay operator
log_step "Step 3: Install KubeRay Operator"

log_info "Adding KubeRay Helm repository"
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>&1 | tee -a "${LOG_FILE}"
helm repo update 2>&1 | tee -a "${LOG_FILE}"

log_info "Installing KubeRay operator v1.3.0"
helm_install "kuberay-operator" "kuberay/kuberay-operator" "${OPERATOR_NAMESPACE}" "--version v1.3.0 --set image.tag=v1.3.0"

log_pass "KubeRay operator Helm chart installed"

# Step 4: Wait for operator to be ready
log_step "Step 4: Wait for Operator Deployment"

if ! wait_for_deployment "kuberay-operator" "${OPERATOR_NAMESPACE}" "300s"; then
    kubectl get pods -n "${OPERATOR_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    kubectl describe pods -n "${OPERATOR_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "KubeRay operator deployment did not become ready"
fi

log_pass "KubeRay operator is ready"

# Step 5: Verify CRDs are registered
log_step "Step 5: Verify CRDs Registration"

REQUIRED_CRDS=("rayclusters.ray.io" "rayjobs.ray.io" "rayservices.ray.io")
ALL_CRDS_FOUND=true

for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "${crd}" &>/dev/null; then
        CRD_INFO=$(kubectl get crd "${crd}" -o jsonpath='{.metadata.name}: {.spec.versions[*].name}')
        log_pass "Found CRD: ${CRD_INFO}"
    else
        log_fail_msg "Missing CRD: ${crd}"
        ALL_CRDS_FOUND=false
    fi
done

if [[ "$ALL_CRDS_FOUND" != "true" ]]; then
    log_fail "Some required CRDs are missing"
fi

log_pass "All required CRDs are registered"

# Step 6: Test webhook validation with invalid resource
log_step "Step 6: Test Webhook Validation"

log_info "Creating an invalid RayCluster spec (missing required fields)"

INVALID_YAML=$(cat <<EOF
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: invalid-cluster
  namespace: ${NAMESPACE}
spec:
  rayVersion: '2.8.0'
  # Missing required headGroupSpec - this should be rejected
  workerGroupSpecs:
  - replicas: 1
    minReplicas: 1
    maxReplicas: 1
    groupName: small-group
    rayStartParams: {}
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray:2.8.0
          resources:
            requests:
              cpu: "1"
              memory: "1Gi"
EOF
)

# Try to apply invalid resource and expect it to fail
APPLY_OUTPUT=""
APPLY_EXIT_CODE=0
APPLY_OUTPUT=$(echo "${INVALID_YAML}" | kubectl apply -f - 2>&1) || APPLY_EXIT_CODE=$?

# Check if the apply command failed OR if output contains error/invalid/rejected
if [[ ${APPLY_EXIT_CODE} -ne 0 ]] || echo "$APPLY_OUTPUT" | grep -qiE "error|invalid|rejected|denied|admission webhook.*denied"; then
    log_pass "Webhook correctly rejected invalid resource"
    log_info "Rejection message: ${APPLY_OUTPUT}"
else
    log_fail "Webhook did not reject invalid resource. Output: ${APPLY_OUTPUT}"
    kubectl delete raycluster invalid-cluster -n "${NAMESPACE}" 2>/dev/null || true
fi

# Step 7: Create and test valid RayCluster
log_step "Step 7: Test Valid RayCluster Reconciliation"

log_info "Creating a valid RayCluster"

cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: test-cluster
  namespace: ${NAMESPACE}
spec:
  rayVersion: '2.8.0'
  enableInTreeAutoscaling: true
  headGroupSpec:
    rayStartParams: {}
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray:2.8.0
          ports:
          - containerPort: 6379
            name: gcs-server
          - containerPort: 8265
            name: dashboard
          - containerPort: 10001
            name: client
          resources:
            limits:
              cpu: "2"
              memory: "4Gi"
            requests:
              cpu: "1"
              memory: "2Gi"
  workerGroupSpecs:
  - replicas: 1
    minReplicas: 1
    maxReplicas: 3
    groupName: small-group
    rayStartParams: {}
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray:2.8.0
          resources:
            limits:
              cpu: "2"
              memory: "4Gi"
            requests:
              cpu: "1"
              memory: "2Gi"
EOF

log_pass "Valid RayCluster created"

# Step 8: Wait for RayCluster to be ready
log_step "Step 8: Wait for RayCluster Ready State"

log_info "Waiting for RayCluster to be ready (may take several minutes)..."
MAX_WAIT=600
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    STATE=$(kubectl get raycluster test-cluster -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "ready" ]]; then
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [[ $((ELAPSED % 60)) -eq 0 ]]; then
        log_info "Still waiting... (${ELAPSED}s elapsed, state: ${STATE})"
    fi
done

# Verify RayCluster reached ready state
if [[ "$STATE" != "ready" ]]; then
    kubectl get raycluster test-cluster -n "${NAMESPACE}" -o wide 2>&1 | tee -a "${LOG_FILE}"
    kubectl get pods -n "${NAMESPACE}" -l ray.io/cluster=test-cluster -o wide 2>&1 | tee -a "${LOG_FILE}"
    log_fail "RayCluster did not reach ready state after ${MAX_WAIT}s (current state: ${STATE})"
fi

# Check RayCluster status
kubectl get raycluster test-cluster -n "${NAMESPACE}" -o wide 2>&1 | tee -a "${LOG_FILE}"
kubectl get pods -n "${NAMESPACE}" -l ray.io/cluster=test-cluster -o wide 2>&1 | tee -a "${LOG_FILE}"

log_pass "RayCluster reconciled successfully"

# Step 9: Test Ray cluster functionality
log_step "Step 9: Test Ray Cluster Functionality"

# Wait for Ray head pod to be ready
if ! wait_for_pod_ready "ray.io/node-type=head" "${NAMESPACE}" "300s"; then
    log_fail "Ray head pod did not become ready"
fi

# Get Ray head pod name
HEAD_POD=$(kubectl get pods -n "${NAMESPACE}" -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')
log_info "Ray head pod: ${HEAD_POD}"

# Test Ray cluster by running a simple Ray job
RAY_TEST_SCRIPT='
import ray
import time
import sys

try:
    # Connect to Ray cluster
    ray.init(address="ray://localhost:10001")

    # Simple Ray task
    @ray.remote
    def hello_world():
        return "Hello from Ray!"

    # Execute task
    result = ray.get(hello_world.remote())
    print(f"Ray task result: {result}")

    # Get cluster resources
    resources = ray.cluster_resources()
    print(f"Cluster resources: {resources}")

    ray.shutdown()
    print("Ray functionality test completed successfully")
    sys.exit(0)

except Exception as e:
    print(f"Ray functionality test failed: {e}")
    sys.exit(1)
'

log_info "Executing Ray functionality test..."
if echo "$RAY_TEST_SCRIPT" | kubectl exec -i "$HEAD_POD" -n "${NAMESPACE}" -- python3 2>&1 | tee -a "${LOG_FILE}"; then
    log_pass "Ray cluster is functional and can execute tasks"
else
    log_fail "Ray cluster functionality test failed"
fi

# Step 10: Test Ray services
log_step "Step 10: Verify Ray Services"

kubectl get services -n "${NAMESPACE}" -l ray.io/cluster=test-cluster -o wide 2>&1 | tee -a "${LOG_FILE}"

if kubectl get service test-cluster-head-svc -n "${NAMESPACE}" &>/dev/null; then
    log_pass "Ray services created successfully"
else
    log_fail "Ray head service not found"
fi

# Final summary
log_step "Test Summary"

log_raw ""
log_raw "Summary:"
log_raw "  ✅ KubeRay operator installed successfully"
log_raw "  ✅ All required CRDs registered"
log_raw "  ✅ Webhook validation working (rejected invalid resource)"
log_raw "  ✅ Valid RayCluster reconciled successfully"
log_raw "  ✅ Ray cluster is functional (executed test tasks)"
log_raw "  ✅ Ray services created properly"
log_raw ""
log_raw "The platform successfully demonstrates that complex AI operators"
log_raw "with CRDs can be installed and function reliably."

finish_test_success "Robust Controller requirement met - KubeRay operator functions correctly with full CRD lifecycle management"
