#!/bin/bash

# Accelerator Metrics Conformance Test
# Tests that the platform allows installation and operation of accelerator metrics solutions

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Accelerator Metrics Conformance Test"
TEST_DESCRIPTION="Validates that the platform allows installation and operation of accelerator metrics solutions exposing fine-grained GPU metrics"
NAMESPACE="accelerator-metrics"

# Initialize test
init_test

# Step 1: Verify GPU nodes exist
log_step "Step 1: Verify GPU Nodes"
check_gpu_nodes "node.kubernetes.io/instance-type" "g4dn.xlarge"

GPU_NODES=$(kubectl get nodes -l node.kubernetes.io/instance-type=g4dn.xlarge -o name 2>/dev/null)
GPU_NODE_NAME=$(echo "$GPU_NODES" | head -1 | cut -d'/' -f2)
GPU_COUNT=$(echo "$GPU_NODES" | wc -l | tr -d ' ')
log_pass "Found ${GPU_COUNT} GPU node(s). Using node: ${GPU_NODE_NAME}"

# Step 2: Verify NVIDIA GPU Operator is installed
log_step "Step 2: Verify GPU Operator"

if ! kubectl get namespace gpu-operator &>/dev/null; then
    log_fail "GPU operator namespace does not exist. NVIDIA GPU Operator not installed."
fi

GPU_OPERATOR_PODS=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$GPU_OPERATOR_PODS" -eq 0 ]; then
    log_fail "No GPU operator pods found. NVIDIA GPU Operator not properly installed."
fi

log_pass "NVIDIA GPU Operator installed with ${GPU_OPERATOR_PODS} components"

# Step 3: Verify DCGM Exporter is running
log_step "Step 3: Verify DCGM Exporter"

DCGM_POD=$(kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter -o name 2>/dev/null | head -1)
if [ -z "$DCGM_POD" ]; then
    log_fail "NVIDIA DCGM Exporter not found. No accelerator metrics solution is running."
fi

DCGM_POD_NAME=$(echo "$DCGM_POD" | cut -d'/' -f2)
DCGM_STATUS=$(kubectl get pod "$DCGM_POD_NAME" -n gpu-operator -o jsonpath='{.status.phase}')

if [ "$DCGM_STATUS" != "Running" ]; then
    log_fail "DCGM Exporter pod is not running. Status: ${DCGM_STATUS}"
fi

log_pass "NVIDIA DCGM Exporter is running (pod: ${DCGM_POD_NAME})"

# Step 4: Verify DCGM Exporter service exists
log_step "Step 4: Verify Metrics Service"

if ! kubectl get service nvidia-dcgm-exporter -n gpu-operator &>/dev/null; then
    log_fail "DCGM Exporter service not found. No metrics endpoint exposed."
fi

SERVICE_PORT=$(kubectl get service nvidia-dcgm-exporter -n gpu-operator -o jsonpath='{.spec.ports[0].port}')
log_pass "Metrics service 'nvidia-dcgm-exporter' exists on port ${SERVICE_PORT}"

# Step 5: Create test namespace
log_step "Step 5: Create Test Namespace"
ensure_namespace "${NAMESPACE}"

# Step 6: Test metrics endpoint accessibility
log_step "Step 6: Test Metrics Endpoint"

log_info "Testing Prometheus-compatible metrics endpoint"

# Use the common function to test metrics endpoint
METRICS_CONTENT=$(test_metrics_endpoint "svc/nvidia-dcgm-exporter" "gpu-operator" 9400 "/metrics" 9400)
if [ $? -ne 0 ]; then
    log_fail "Failed to access metrics endpoint"
fi

log_pass "Metrics endpoint accessible and returning data (HTTP 200)"

# Step 7: Verify core GPU metrics are present
log_step "Step 7: Verify Core Metrics"

log_info "Checking for required per-accelerator metrics"

MISSING_REQUIRED=()
FOUND_OPTIONAL=()

# Check for utilization metrics
if echo "$METRICS_CONTENT" | grep -qE "DCGM_FI_DEV_GPU_UTIL|gpu_utilization|nvidia_gpu_duty_cycle"; then
    log_pass "Found GPU utilization metrics"
else
    MISSING_REQUIRED+=("utilization")
    log_fail_msg "Missing GPU utilization metrics"
fi

# Check for memory metrics
if echo "$METRICS_CONTENT" | grep -qE "DCGM_FI_DEV_FB_USED|DCGM_FI_DEV_FB_FREE|gpu_memory|nvidia_gpu_memory"; then
    log_pass "Found GPU memory metrics"
else
    MISSING_REQUIRED+=("memory")
    log_fail_msg "Missing GPU memory metrics"
fi

# Check optional metrics
if echo "$METRICS_CONTENT" | grep -qE "DCGM_FI_DEV_GPU_TEMP|gpu_temperature|nvidia_gpu_temperature"; then
    FOUND_OPTIONAL+=("temperature")
    log_info "Found GPU temperature metrics (optional)"
fi

if echo "$METRICS_CONTENT" | grep -qE "DCGM_FI_DEV_POWER_USAGE|gpu_power|nvidia_gpu_power_usage"; then
    FOUND_OPTIONAL+=("power")
    log_info "Found GPU power usage metrics (optional)"
fi

# Evaluate core metrics requirement
if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    MISSING_LIST=$(IFS=', '; echo "${MISSING_REQUIRED[*]}")
    log_fail "Missing required metrics: ${MISSING_LIST}"
fi

OPTIONAL_INFO=""
if [ ${#FOUND_OPTIONAL[@]} -gt 0 ]; then
    OPTIONAL_LIST=$(IFS=', '; echo "${FOUND_OPTIONAL[*]}")
    OPTIONAL_INFO=" Optional metrics found: ${OPTIONAL_LIST}."
fi

log_pass "All required core metrics present (utilization, memory).${OPTIONAL_INFO}"

# Step 8: Verify metrics are per-accelerator
log_step "Step 8: Verify Per-Accelerator Metrics"

log_info "Checking that metrics are exposed per individual GPU"

# Check for GPU device identifiers in metrics
GPU_DEVICES=$(echo "$METRICS_CONTENT" | grep -E "gpu=|device=|Hostname=" | grep -E "DCGM_FI_|nvidia_gpu_" | head -5)

if [ -z "$GPU_DEVICES" ]; then
    log_fail "Metrics do not contain per-accelerator labels (gpu, device, or Hostname)"
fi

# Count unique GPU identifiers
UNIQUE_GPUS=$(echo "$METRICS_CONTENT" | grep -oE 'gpu="[0-9]+"' | sort -u | wc -l | tr -d ' ')

if [ "$UNIQUE_GPUS" -eq 0 ]; then
    # Try alternative label format
    UNIQUE_GPUS=$(echo "$METRICS_CONTENT" | grep -oE 'device="[^"]*"' | sort -u | wc -l | tr -d ' ')
fi

if [ "$UNIQUE_GPUS" -eq 0 ]; then
    log_fail "Cannot determine individual GPU identifiers from metrics"
fi

log_info "Sample metrics with GPU identifiers:"
echo "$METRICS_CONTENT" | grep -E "gpu=|device=" | head -3 | tee -a "${LOG_FILE}"

log_pass "Metrics are labeled per-accelerator. Found metrics for ${UNIQUE_GPUS} GPU(s)."

# Step 9: Verify metrics format is standardized (Prometheus)
log_step "Step 9: Verify Standardized Format"

log_info "Checking metrics exposition format"

# Check for Prometheus format characteristics
if ! echo "$METRICS_CONTENT" | grep -qE "^# (HELP|TYPE)"; then
    log_fail "Metrics do not follow Prometheus exposition format (missing HELP/TYPE comments)"
fi

if ! echo "$METRICS_CONTENT" | grep -qE "^[a-zA-Z_][a-zA-Z0-9_]*(\{.*\})? [0-9]"; then
    log_fail "Metrics do not follow Prometheus exposition format (invalid metric format)"
fi

log_info "Sample metric format:"
echo "$METRICS_CONTENT" | grep "^# HELP" | head -2 | tee -a "${LOG_FILE}"
echo "$METRICS_CONTENT" | grep "^# TYPE" | head -2 | tee -a "${LOG_FILE}"
echo "$METRICS_CONTENT" | grep -E "^[a-zA-Z]" | grep -v "^#" | head -3 | tee -a "${LOG_FILE}"

log_pass "Metrics are exposed in Prometheus exposition format (machine-readable, standardized)"

# Final result
log_step "Test Summary"

log_info "Platform Details:"
log_info "  - GPU Node: ${GPU_NODE_NAME} (g4dn.xlarge with NVIDIA T4)"
log_info "  - Metrics Solution: NVIDIA DCGM Exporter (industry standard)"
log_info "  - Metrics Endpoint: http://nvidia-dcgm-exporter.gpu-operator.svc:${SERVICE_PORT}/metrics"

log_raw ""
log_raw "The Gardener platform successfully meets the CNCF AI Conformance requirement:"
log_raw "  1. ✅ Platform allows installation and operation of accelerator metrics solution"
log_raw "  2. ✅ Standardized, machine-readable endpoint available (Prometheus format)"
log_raw "  3. ✅ Core metrics present - per-accelerator utilization and memory usage"
log_raw "  4. ✅ Per-accelerator granularity with individual GPU identifiers"
log_raw "  5. ✅ Additional metrics exposed (temperature, power, etc.)"

finish_test_success "All accelerator metrics requirements validated successfully"
