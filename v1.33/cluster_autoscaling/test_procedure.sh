#!/bin/bash

# Cluster Autoscaling Conformance Test
# Tests cluster autoscaling with GPU accelerator workloads

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Cluster Autoscaling with GPU Accelerators"
TEST_DESCRIPTION="Validates that cluster autoscaler scales GPU node groups based on pending GPU workloads"
NAMESPACE="cluster-autoscaling"
GPU_NODE_POOL_LABEL="worker.garden.sapcloud.io/group=worker-gpu"

# Initialize test
init_test

# Check prerequisites
check_kubernetes_access

# Helper function to get GPU allocation info
get_gpu_allocation_info() {
    local nodes=$(kubectl get nodes -l "${GPU_NODE_POOL_LABEL}" -o jsonpath='{.items[*].metadata.name}')
    local total_gpus=0
    local allocated_gpus=0

    for node in $nodes; do
        local capacity=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
        local allocated=$(kubectl describe node "$node" | grep -A 5 "Allocated resources:" | grep "nvidia.com/gpu" | awk '{print $2}' 2>/dev/null || echo "0")
        total_gpus=$((total_gpus + capacity))
        allocated_gpus=$((allocated_gpus + allocated))
    done

    echo "$allocated_gpus/$total_gpus"
}

# Step 1: Verify GPU infrastructure
log_step "Step 1: Verify GPU Infrastructure"

log_info "Checking for GPU nodes..."
GPU_NODES=$(kubectl get nodes -l "${GPU_NODE_POOL_LABEL}" -o name 2>/dev/null || true)

if [ -z "$GPU_NODES" ]; then
    log_fail "No GPU nodes found with label ${GPU_NODE_POOL_LABEL}"
fi

GPU_NODE_NAME=$(echo "$GPU_NODES" | head -1 | cut -d'/' -f2)
GPU_COUNT=$(echo "$GPU_NODES" | wc -l | tr -d ' ')
log_pass "Found ${GPU_COUNT} GPU node(s) - first node: ${GPU_NODE_NAME}"

log_info "Checking GPU device plugin..."
if ! kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q Running; then
    log_fail "NVIDIA device plugin not running"
fi
log_pass "NVIDIA GPU device plugin is running"

INITIAL_GPU_ALLOCATION=$(get_gpu_allocation_info)
log_info "Initial GPU allocation: ${INITIAL_GPU_ALLOCATION}"

# Step 2: Create test namespace
log_step "Step 2: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created"

# Step 3: Record initial state
log_step "Step 3: Record Initial Cluster State"

INITIAL_NODE_COUNT=$(get_gpu_node_count "${GPU_NODE_POOL_LABEL}")
log_info "Initial GPU node count: ${INITIAL_NODE_COUNT}"

if [ "$INITIAL_NODE_COUNT" -ne 1 ]; then
    log_warn "Expected 1 initial GPU node, found ${INITIAL_NODE_COUNT}"
fi

# Step 4: Deploy GPU workload requiring scale-up
log_step "Step 4: Deploy GPU Workload Requiring Scale-Up"

log_info "Creating deployment with 2 pods requiring 1 GPU each (exceeds single node capacity)"
log_info "Important: No nodeAffinity used - autoscaler must react to GPU requests only"

cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-test-workload
  namespace: ${NAMESPACE}
  labels:
    app: gpu-test-workload
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gpu-test-workload
  template:
    metadata:
      labels:
        app: gpu-test-workload
        workload-type: gpu-accelerator
    spec:
      containers:
      - name: gpu-consumer
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            nvidia.com/gpu: 1
          limits:
            nvidia.com/gpu: 1
EOF

log_pass "GPU workload deployment created (2 replicas × 1 GPU each)"

# Step 5: Wait for initial scheduling
log_step "Step 5: Wait for Initial Pod Scheduling"

sleep 30

RUNNING_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-test-workload --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PENDING_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-test-workload --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

log_info "Current pod state: ${RUNNING_PODS} running, ${PENDING_PODS} pending"

if [ "$RUNNING_PODS" -ne 1 ] || [ "$PENDING_PODS" -ne 1 ]; then
    log_warn "Expected 1 running and 1 pending pod, got ${RUNNING_PODS} running and ${PENDING_PODS} pending"
else
    log_pass "Expected pod distribution: 1 running (node capacity reached), 1 pending (needs additional node)"
fi

# Step 6: Wait for cluster autoscaler to scale up
log_step "Step 6: Wait for Cluster Autoscaler Scale-Up"

SCALE_UP_SUCCESS=false
TEST_PASSED=true
if wait_for_gpu_node_count 2 "${GPU_NODE_POOL_LABEL}" 900; then
    SCALE_UP_SUCCESS=true
    log_pass "Cluster autoscaler successfully scaled up to 2 GPU nodes"
else
    log_fail_msg "Cluster autoscaler failed to scale up within 15 minutes"
    TEST_PASSED=false
fi

POST_SCALE_NODE_COUNT=$(get_gpu_node_count "${GPU_NODE_POOL_LABEL}")
POST_SCALE_GPU_ALLOCATION=$(get_gpu_allocation_info)
log_info "Post-scale GPU node count: ${POST_SCALE_NODE_COUNT}"
log_info "Post-scale GPU allocation: ${POST_SCALE_GPU_ALLOCATION}"

# Step 7: Wait for device plugin on new nodes
log_step "Step 7: Wait for GPU Device Plugin on All Nodes"

log_info "Waiting for GPU device plugin to initialize on all nodes..."
MAX_PLUGIN_WAIT=300
PLUGIN_START=$(date +%s)
ALL_NODES_READY=false

while [ $(($(date +%s) - PLUGIN_START)) -lt $MAX_PLUGIN_WAIT ]; do
    GPU_NODES_COUNT=$(kubectl get nodes -l "${GPU_NODE_POOL_LABEL}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    PLUGIN_PODS=$(kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

    log_info "GPU nodes: ${GPU_NODES_COUNT}, Device plugin pods running: ${PLUGIN_PODS}"

    if [ "$GPU_NODES_COUNT" -eq "$PLUGIN_PODS" ] && [ "$GPU_NODES_COUNT" -eq 2 ]; then
        ALL_NODES_READY=true
        log_pass "GPU device plugin running on all GPU nodes"
        break
    fi

    sleep 15
done

if [ "$ALL_NODES_READY" != true ]; then
    log_fail_msg "GPU device plugin not ready on all nodes after timeout"
    kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset -o wide 2>&1 | tee -a "${LOG_FILE}"
    TEST_PASSED=false
fi

# Additional wait for GPU resources to be advertised
log_info "Waiting for GPU resources to be advertised on new nodes..."
sleep 60

# Verify GPU resources
NODES_WITH_GPUS=$(kubectl get nodes -l "${GPU_NODE_POOL_LABEL}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | grep -c "1$" || echo "0")
log_info "Nodes advertising GPU resources: ${NODES_WITH_GPUS}"

if [ "$NODES_WITH_GPUS" -ne 2 ]; then
    log_fail_msg "Not all GPU nodes are advertising GPU resources (expected 2, got ${NODES_WITH_GPUS})"
    kubectl get nodes -l "${GPU_NODE_POOL_LABEL}" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>&1 | tee -a "${LOG_FILE}"
    TEST_PASSED=false
fi

# Step 8: Verify all pods are scheduled
log_step "Step 8: Verify All Pods Are Scheduled"

MAX_WAIT=180
START_TIME=$(date +%s)
FINAL_RUNNING=0
FINAL_PENDING=0

while [ $(($(date +%s) - START_TIME)) -lt $MAX_WAIT ]; do
    FINAL_RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-test-workload --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    FINAL_PENDING=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-test-workload --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

    log_info "Current pod state: ${FINAL_RUNNING} running, ${FINAL_PENDING} pending"

    if [ "$FINAL_RUNNING" -eq 2 ] && [ "$FINAL_PENDING" -eq 0 ]; then
        log_pass "All pods successfully scheduled on GPU nodes"
        break
    fi

    sleep 15
done

if [ "$FINAL_RUNNING" -ne 2 ] || [ "$FINAL_PENDING" -ne 0 ]; then
    log_fail_msg "Not all pods scheduled after scale up (expected 2 running, got ${FINAL_RUNNING} running, ${FINAL_PENDING} pending)"
    kubectl get pods -n "${NAMESPACE}" -o wide 2>&1 | tee -a "${LOG_FILE}"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 2>&1 | tee -a "${LOG_FILE}"
    TEST_PASSED=false
fi

# Step 9: Test scale down
log_step "Step 9: Test Scale Down"

log_info "Deleting GPU workload to trigger scale down..."
kubectl delete deployment gpu-test-workload -n "${NAMESPACE}" --timeout=60s 2>&1 | tee -a "${LOG_FILE}"

sleep 30
REMAINING_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
log_info "Remaining pods in namespace: ${REMAINING_PODS}"

log_info "Waiting for cluster autoscaler to scale down (may take up to 20 minutes)..."
SCALE_DOWN_SUCCESS=false
if wait_for_gpu_node_count 1 "${GPU_NODE_POOL_LABEL}" 1200; then
    SCALE_DOWN_SUCCESS=true
    log_pass "Cluster autoscaler successfully scaled down to 1 GPU node"
else
    log_warn "Scale down did not complete within timeout (may be expected based on autoscaler settings)"
fi

FINAL_NODE_COUNT=$(get_gpu_node_count "${GPU_NODE_POOL_LABEL}")
FINAL_GPU_ALLOCATION=$(get_gpu_allocation_info)
log_info "Final GPU node count: ${FINAL_NODE_COUNT}"
log_info "Final GPU allocation: ${FINAL_GPU_ALLOCATION}"

# Final summary
log_step "Test Summary"

log_raw ""
log_raw "Test Results:"
log_raw "  Initial GPU Nodes: ${INITIAL_NODE_COUNT}"
log_raw "  Scale Up Target: 2 nodes"
log_raw "  Post-Scale Nodes: ${POST_SCALE_NODE_COUNT}"
log_raw "  Final Running Pods: ${FINAL_RUNNING}"
log_raw "  Scale Down Target: 1 node"
log_raw "  Final Nodes: ${FINAL_NODE_COUNT}"
log_raw ""

if [ "$TEST_PASSED" = true ] && [ "$SCALE_UP_SUCCESS" = true ] && [ "$FINAL_RUNNING" -eq 2 ]; then
    log_raw "CONFORMANCE STATUS: ✅ PASSED"
    log_raw ""
    log_raw "The cluster autoscaler successfully:"
    log_raw "  ✅ Scaled up GPU nodes when workloads exceeded capacity"
    log_raw "  ✅ Pending pods requesting GPUs triggered scale-up correctly"
    log_raw "  ✅ All GPU pods were scheduled after scale-up completed"
    if [ "$SCALE_DOWN_SUCCESS" = true ]; then
        log_raw "  ✅ Scaled down GPU nodes when workloads were removed"
    else
        log_raw "  ⚠️  Scale down pending (may take additional time based on autoscaler configuration)"
    fi
    log_raw ""
    log_raw "The platform meets the cluster autoscaling requirement for GPU accelerator workloads."

    finish_test_success "Cluster autoscaler correctly scaled GPU nodes based on pending GPU workloads"
else
    log_raw "CONFORMANCE STATUS: ❌ FAILED"
    log_raw ""
    log_raw "Issues identified:"
    [ "$SCALE_UP_SUCCESS" != true ] && log_raw "  ❌ Cluster did not scale up GPU nodes as expected"
    [ "$FINAL_RUNNING" -ne 2 ] && log_raw "  ❌ Not all GPU pods were scheduled (requirement violation)"
    log_raw ""

    finish_test_failure "Cluster autoscaling requirement not met - scale-up or pod scheduling failed"
fi
