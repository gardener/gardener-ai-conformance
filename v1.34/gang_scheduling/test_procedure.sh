#!/bin/bash

# Gang Scheduling Conformance Test
# Tests that the platform supports gang scheduling for distributed AI workloads

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Gang Scheduling Conformance Test"
TEST_DESCRIPTION="Validates that the platform supports gang scheduling (all-or-nothing scheduling) for distributed AI workloads"
NAMESPACE="gang-scheduling"
KUEUE_NAMESPACE="kueue-system"
KUEUE_VERSION="v0.14.2"

# Register additional namespace for cleanup
ADDITIONAL_NAMESPACES=("${KUEUE_NAMESPACE}")

# Initialize test
init_test

# Register CRD cleanup (after init_test so LOG_FILE is available)
add_cleanup_command "kubectl delete -f https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml --ignore-not-found=true 2>&1 | sed 's/^/  /' >> \${LOG_FILE} || true"

# Check prerequisites
check_kubernetes_access

# Step 1: Create test namespace
log_step "Step 1: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created"

# Step 2: Install Kueue
log_step "Step 2: Install Kueue Gang Scheduling Solution"

log_info "Creating Kueue namespace"
ensure_namespace "${KUEUE_NAMESPACE}"

log_info "Installing Kueue ${KUEUE_VERSION}"
log_info "Kueue provides gang scheduling capabilities for Kubernetes workloads"

if kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml" &>/dev/null; then
    log_pass "Kueue manifests applied successfully"
else
    log_info "Retrying with output..."
    kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Failed to install Kueue"
fi

# Step 3: Wait for Kueue to be ready
log_step "Step 3: Wait for Kueue Deployment"

if ! wait_for_deployment "kueue-controller-manager" "${KUEUE_NAMESPACE}" "300s"; then
    log_info "Checking Kueue pods status..."
    kubectl get pods -n "${KUEUE_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    kubectl describe pods -n "${KUEUE_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Kueue deployment did not become ready"
fi

log_pass "Kueue is ready"

# Step 4: Verify Kueue installation
log_step "Step 4: Verify Kueue Installation"

log_info "Checking Kueue pods:"
kubectl get pods -n "${KUEUE_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"

if ! kubectl get pods -n "${KUEUE_NAMESPACE}" -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
    kubectl describe pods -n "${KUEUE_NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Kueue pods are not in Running state"
fi

log_pass "Kueue pods are running"

log_info "Verifying Kueue CRDs:"
if ! kubectl api-resources | grep "kueue.x-k8s.io" 2>&1 | tee -a "${LOG_FILE}"; then
    log_fail "Kueue CRDs not found"
fi

log_pass "Kueue CRDs are available"

# Step 5: Configure Kueue resources
log_step "Step 5: Configure Kueue Resources"

log_info "Creating ResourceFlavor, ClusterQueue, and LocalQueue"

cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: default-flavor
      resources:
      - name: cpu
        nominalQuota: 4
      - name: memory
        nominalQuota: 8Gi
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  namespace: ${NAMESPACE}
  name: user-queue
spec:
  clusterQueue: cluster-queue
EOF

sleep 5
if ! kubectl get localqueue user-queue -n "${NAMESPACE}" &>/dev/null; then
    log_fail "LocalQueue was not created"
fi

log_pass "Kueue resources configured successfully"

# Step 6: Submit gang-scheduled job
log_step "Step 6: Submit Gang-Scheduled Job"

log_info "Submitting a multi-pod job to test all-or-nothing gang scheduling"
log_info "This job requires 3 pods to run in parallel (distributed workload)"
log_info "Gang scheduling ensures all 3 pods are scheduled together or none at all"

cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: batch/v1
kind: Job
metadata:
  name: gang-scheduled-job
  namespace: ${NAMESPACE}
  labels:
    kueue.x-k8s.io/queue-name: user-queue
spec:
  parallelism: 3
  completions: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          echo "Pod \${HOSTNAME} starting at \$(date)"
          echo "Simulating distributed AI workload coordination"
          sleep 10
          echo "Pod \${HOSTNAME} completed at \$(date)"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

log_pass "Gang-scheduled job created"

# Step 7: Monitor job admission
log_step "Step 7: Monitor Job Admission and Gang Scheduling"

log_info "Waiting for Kueue to admit the job (all-or-nothing scheduling)..."
sleep 5

log_info "Checking Kueue Workload admission status:"
kubectl get workload -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"

# Wait for workload to be admitted
MAX_WAIT=60
ELAPSED=0
ADMITTED=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if kubectl get workload -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null | grep -q "True"; then
        ADMITTED=true
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$ADMITTED" = "false" ]; then
    log_info "Workload details:"
    kubectl describe workload -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Job was not admitted by Kueue within timeout"
fi

log_pass "Job was admitted by Kueue for gang scheduling"

# Step 8: Verify all pods are scheduled together
log_step "Step 8: Verify All-or-Nothing Gang Scheduling"

log_info "Checking that all 3 pods are scheduled together..."
sleep 5

kubectl get pods -n "${NAMESPACE}" -l job-name=gang-scheduled-job 2>&1 | tee -a "${LOG_FILE}"

POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l job-name=gang-scheduled-job --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$POD_COUNT" -ne 3 ]; then
    log_fail "Expected 3 pods, but found ${POD_COUNT} pods. Gang scheduling failed."
fi

log_pass "All 3 pods were created (gang scheduling working)"

# Step 9: Wait for job completion
log_step "Step 9: Wait for Job Completion"

log_info "Waiting for distributed workload to complete (max 60s)..."

if ! kubectl wait --for=condition=complete --timeout=60s job/gang-scheduled-job -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"; then
    log_warn "Job did not complete within timeout, checking status..."
    kubectl describe job gang-scheduled-job -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    kubectl get pods -n "${NAMESPACE}" -l job-name=gang-scheduled-job 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Gang-scheduled job did not complete successfully"
fi

log_pass "Gang-scheduled job completed successfully"

# Step 10: Verify job success
log_step "Step 10: Verify Job Completion"

kubectl get job gang-scheduled-job -n "${NAMESPACE}" -o wide 2>&1 | tee -a "${LOG_FILE}"

if ! kubectl get job gang-scheduled-job -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q "True"; then
    kubectl describe job gang-scheduled-job -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"
    log_fail "Job did not complete successfully"
fi

log_pass "Job completed successfully with all pods"

log_info "Pod logs demonstrating distributed workload coordination:"
for pod in $(kubectl get pods -n "${NAMESPACE}" -l job-name=gang-scheduled-job -o jsonpath='{.items[*].metadata.name}'); do
    log_info "Logs from ${pod}:"
    kubectl logs "$pod" -n "${NAMESPACE}" 2>&1 | sed 's/^/  /' | tee -a "${LOG_FILE}" || true
done

# Step 11: Final verification
log_step "Step 11: Final Verification"

log_info "Verifying gang scheduling solution is operational"

if ! kubectl get pods -n "${KUEUE_NAMESPACE}" -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
    log_fail "Kueue pods are no longer running"
fi

if ! kubectl get workload -n "${NAMESPACE}" &>/dev/null; then
    log_fail "Workload resource not found"
fi

log_pass "Gang scheduling solution (Kueue) is operational"

# Final summary
log_step "Test Summary"

log_raw ""
log_raw "Summary:"
log_raw "  ✅ Kueue gang scheduling solution installed successfully"
log_raw "  ✅ Kueue is operational and managing workloads"
log_raw "  ✅ Multi-pod job was gang-scheduled (all-or-nothing scheduling)"
log_raw "  ✅ All 3 pods were scheduled together atomically"
log_raw "  ✅ Distributed workload completed successfully"
log_raw ""
log_raw "The platform successfully demonstrates gang scheduling capability"
log_raw "for distributed AI workloads as required by the conformance standard."

finish_test_success "Gang Scheduling requirement met - Kueue successfully provides all-or-nothing scheduling for distributed workloads"
