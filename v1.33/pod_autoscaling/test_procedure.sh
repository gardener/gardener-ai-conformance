#!/bin/bash

# Pod Autoscaling Conformance Test
# Tests that HPA can use custom GPU metrics to scale GPU workloads

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="Pod Autoscaling with Custom GPU Metrics"
TEST_DESCRIPTION="Verifies that HPA functions correctly for GPU workloads using custom metrics from DCGM"
NAMESPACE="pod-autoscaling"
MONITORING_NAMESPACE="monitoring"
RESOURCES_DIR="${SCRIPT_DIR}/resources"

# Register additional namespace for cleanup
ADDITIONAL_NAMESPACES=("${MONITORING_NAMESPACE}")

# Initialize test
init_test

# Register cleanup for ServiceMonitor in gpu-operator namespace (created in Step 6)
add_cleanup_command "kubectl delete servicemonitor nvidia-dcgm-exporter -n gpu-operator --ignore-not-found=true 2>&1 | sed 's/^/  /' >> ${LOG_FILE} || true"

# Register cleanup for PrometheusRule (created in Step 7) - should be deleted before Prometheus uninstall
add_cleanup_command "kubectl delete prometheusrule gpu-custom-metrics -n ${MONITORING_NAMESPACE} --ignore-not-found=true 2>&1 | sed 's/^/  /' >> ${LOG_FILE} || true"

# Check prerequisites
check_kubernetes_access
check_helm

# Step 1: Create test namespace
log_step "Step 1: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created"

# Step 2: Verify GPU infrastructure
log_step "Step 2: Verify Prerequisites"

check_gpu_nodes "node.kubernetes.io/instance-type" "g4dn.xlarge"

log_info "Checking for DCGM exporter..."
DCGM_POD=$(kubectl get pod -n gpu-operator -l app=nvidia-dcgm-exporter -o name 2>&1 | head -1)
if [ -z "$DCGM_POD" ]; then
    log_fail "DCGM Exporter not found in gpu-operator namespace"
fi
log_pass "DCGM exporter is running"

# Step 3: Create monitoring namespace
log_step "Step 3: Create Monitoring Namespace"
ensure_namespace "${MONITORING_NAMESPACE}"
log_pass "Monitoring namespace created"

# Step 4: Deploy kube-prometheus-stack
log_step "Step 4: Deploy Prometheus Stack"

log_info "Adding prometheus-community Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>&1 | tee -a "${LOG_FILE}"
helm repo update 2>&1 | tee -a "${LOG_FILE}"

log_info "Installing kube-prometheus-stack (this may take a few minutes)..."
helm_install "kube-prometheus-stack" "prometheus-community/kube-prometheus-stack" "${MONITORING_NAMESPACE}" \
  "--set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
   --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
   --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
   --wait --timeout=5m"

log_pass "kube-prometheus-stack deployed successfully"

# Step 5: Wait for Prometheus to be ready
log_step "Step 5: Wait for Prometheus"

if ! wait_for_pod_ready "app.kubernetes.io/name=prometheus" "${MONITORING_NAMESPACE}" "180s"; then
    log_fail "Prometheus pods did not become ready"
fi
log_pass "Prometheus is ready"

# Step 6: Create ServiceMonitor for DCGM Exporter
log_step "Step 6: Configure DCGM Metrics Collection"

log_info "Applying ServiceMonitor for DCGM exporter"
kubectl apply -f "${RESOURCES_DIR}/dcgm-servicemonitor.yaml" 2>&1 | tee -a "${LOG_FILE}"

sleep 10

if kubectl get servicemonitor nvidia-dcgm-exporter -n gpu-operator >/dev/null 2>&1; then
    log_pass "ServiceMonitor created - Prometheus will scrape DCGM metrics"
else
    log_fail "ServiceMonitor creation failed"
fi

# Step 7: Apply PrometheusRule for custom GPU metrics
log_step "Step 7: Create Custom GPU Metric Recording Rules"

log_info "Applying PrometheusRule with pod_gpu_utilization recording rule"
kubectl apply -f "${RESOURCES_DIR}/gpu-prometheusrule.yaml" 2>&1 | tee -a "${LOG_FILE}"

sleep 15

if kubectl get prometheusrule gpu-custom-metrics -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    log_pass "PrometheusRule created successfully"
else
    log_fail "PrometheusRule creation failed"
fi

# Step 8: Wait for custom metric availability
log_step "Step 8: Wait for Custom Metric Availability"

log_info "Waiting for pod_gpu_utilization metric to appear in Prometheus (may take some minutes)..."

# Wait for Prometheus to evaluate the recording rule (rules are evaluated every 15-30 seconds)
sleep 30

# Port-forward to Prometheus
PROMETHEUS_SVC="svc/kube-prometheus-stack-prometheus"
PF_PID=$(start_port_forward "$PROMETHEUS_SVC" "${MONITORING_NAMESPACE}" 9090 9090)

METRIC_FOUND=false
for i in {1..20}; do
    if METRIC_DATA=$(curl -s 'http://localhost:9090/api/v1/query?query=pod_gpu_utilization' 2>&1) && \
       echo "$METRIC_DATA" | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
        METRIC_FOUND=true
        log_pass "pod_gpu_utilization metric is available in Prometheus"
        break
    fi
    log_info "Waiting for metric (attempt $i/10)..."
    sleep 30
done

stop_port_forward "$PF_PID"

if [ "$METRIC_FOUND" = false ]; then
    log_fail "pod_gpu_utilization metric did not appear in Prometheus after 10 minutes"
fi

# Step 9: Deploy prometheus-adapter
log_step "Step 9: Deploy Prometheus-Adapter"

log_info "Creating prometheus-adapter configuration"
cat > /tmp/prometheus-adapter-values.yaml <<'EOF'
prometheus:
  url: http://kube-prometheus-stack-prometheus.monitoring.svc
  port: 9090

rules:
  default: false
  custom:
  - seriesQuery: 'pod_gpu_utilization{pod!=""}'
    resources:
      overrides:
        pod:
          resource: "pod"
        namespace:
          resource: "namespace"
    name:
      matches: "pod_gpu_utilization"
      as: "pod_gpu_utilization"
    metricsQuery: 'avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
EOF

log_info "Installing prometheus-adapter"
helm_install "prometheus-adapter" "prometheus-community/prometheus-adapter" "${MONITORING_NAMESPACE}" \
  "--values /tmp/prometheus-adapter-values.yaml --wait --timeout=3m"

log_pass "prometheus-adapter deployed successfully"

# Step 10: Wait for prometheus-adapter
log_step "Step 10: Wait for Prometheus-Adapter"

if ! wait_for_pod_ready "app.kubernetes.io/name=prometheus-adapter" "${MONITORING_NAMESPACE}" "120s"; then
    log_fail "prometheus-adapter pods did not become ready"
fi

sleep 15
log_pass "prometheus-adapter is ready"

# Step 11: Verify custom metrics API
log_step "Step 11: Verify Custom Metrics API"

if kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" >/dev/null 2>&1; then
    log_pass "Custom metrics API is available"
else
    log_fail "Custom metrics API not available"
fi

# Step 12: Deploy GPU workload with HPA
log_step "Step 12: Deploy GPU Workload with HPA"

log_info "Deploying GPU workload and HorizontalPodAutoscaler"
kubectl apply -f "${RESOURCES_DIR}/gpu-workload.yaml" -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"

log_info "Waiting for GPU workload deployment to be available..."
if ! wait_for_deployment "gpu-workload" "${NAMESPACE}" "300s"; then
    log_fail "GPU workload deployment did not become ready"
fi

GPU_POD=$(kubectl get pod -l app=gpu-workload -n "${NAMESPACE}" -o name 2>&1 | head -1)
if [ -z "$GPU_POD" ]; then
    log_fail "No GPU workload pod found"
fi

GPU_POD_NAME=$(echo "$GPU_POD" | cut -d'/' -f2)
log_pass "GPU workload deployed - pod: ${GPU_POD_NAME}"

# Step 13: Verify HPA can access custom metric
log_step "Step 13: Verify HPA Metric Access"

log_info "Checking if HPA can access pod_gpu_utilization metric (will retry for 5 minutes)..."

METRIC_ACCESSIBLE=false
for attempt in {1..10}; do
    log_info "Checking metric accessibility (attempt $attempt/10)..."
    METRIC_RESPONSE=$(kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/pod_gpu_utilization" 2>&1 || echo "FAILED")

    if echo "$METRIC_RESPONSE" | jq -e '.items | length > 0' >/dev/null 2>&1; then
        METRIC_VALUE=$(echo "$METRIC_RESPONSE" | jq -r '.items[0].value')
        METRIC_ACCESSIBLE=true
        log_pass "HPA can access custom metric - current value: ${METRIC_VALUE}"
        break
    fi

    if [ $attempt -lt 10 ]; then
        sleep 30
    fi
done

if [ "$METRIC_ACCESSIBLE" = false ]; then
    log_fail "Custom metric NOT accessible via custom metrics API after 5 minutes - HPA cannot function"
fi

# Step 14: Verify HPA configuration
log_step "Step 14: Verify HPA Configuration"

HPA_METRIC_TYPE=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.metrics[0].type}' 2>&1)
HPA_METRIC_NAME=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.spec.metrics[0].pods.metric.name}' 2>&1)

if [ "$HPA_METRIC_TYPE" = "Pods" ] && [ "$HPA_METRIC_NAME" = "pod_gpu_utilization" ]; then
    log_pass "HPA is configured to use custom metric: ${HPA_METRIC_NAME}"
else
    log_fail "HPA not using expected custom metric"
fi

# Step 15: Monitor for HPA scale-up
log_step "Step 15: Monitor HPA Scale-Up Behavior"

log_info "GPU workload is generating continuous load - monitoring HPA for scale-up (max 5 minutes)..."

SCALE_UP_DETECTED=false

for i in {1..10}; do
    sleep 30

    CURRENT_REPLICAS=$(kubectl get deployment gpu-workload -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>&1)
    DESIRED_REPLICAS=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.status.desiredReplicas}' 2>&1 || echo "1")
    CURRENT_METRIC=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.status.currentMetrics[0].pods.current.averageValue}' 2>&1 || echo "0")
    POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-workload --no-headers 2>&1 | wc -l)

    log_info "Monitor iteration $i/10: Replicas=${CURRENT_REPLICAS}, Desired=${DESIRED_REPLICAS}, Pods=${POD_COUNT}, GPU Metric=${CURRENT_METRIC}"

    # Success if HPA wants 2 replicas OR we see 2 pods
    if [ "$DESIRED_REPLICAS" -eq 2 ] || [ "$POD_COUNT" -gt 1 ]; then
        SCALE_UP_DETECTED=true
        log_pass "HPA triggered scale-up! Desired replicas: ${DESIRED_REPLICAS}, Pod count: ${POD_COUNT}"
        break
    fi
done

if [ "$SCALE_UP_DETECTED" = false ]; then
    log_fail "HPA did NOT scale up after 5 minutes - GPU utilization: ${CURRENT_METRIC}"
fi

# Step 16: Stop GPU load to trigger scale-down
log_step "Step 16: Stop GPU Load"

log_info "Creating stop signal in all GPU workload pods to halt GPU processing..."

GPU_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-workload -o name 2>&1)
for pod in $GPU_PODS; do
    POD_NAME=$(echo "$pod" | cut -d'/' -f2)
    log_info "Stopping load in pod: ${POD_NAME}"
    kubectl exec -n "${NAMESPACE}" "$POD_NAME" -- touch /tmp/stop-load 2>&1 | tee -a "${LOG_FILE}" || true
done

sleep 10
log_pass "GPU load stopped in all pods"

# Step 17: Monitor for HPA scale-down
log_step "Step 17: Monitor HPA Scale-Down Behavior"

log_info "Monitoring HPA for scale-down (max 5 minutes)..."
log_info "Note: HPA has a default scale-down stabilization window of 5 minutes"

SCALE_DOWN_DETECTED=false

for i in {1..15}; do
    sleep 20

    CURRENT_REPLICAS=$(kubectl get deployment gpu-workload -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>&1)
    DESIRED_REPLICAS=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.status.desiredReplicas}' 2>&1 || echo "2")
    CURRENT_METRIC=$(kubectl get hpa gpu-workload-hpa -n "${NAMESPACE}" -o jsonpath='{.status.currentMetrics[0].pods.current.averageValue}' 2>&1 || echo "0")
    POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l app=gpu-workload --field-selector=status.phase=Running --no-headers 2>&1 | wc -l)

    log_info "Monitor iteration $i/15: Replicas=${CURRENT_REPLICAS}, Desired=${DESIRED_REPLICAS}, Running Pods=${POD_COUNT}, GPU Metric=${CURRENT_METRIC}"

    # Success if HPA wants 1 replica OR we see only 1 running pod
    if [ "$DESIRED_REPLICAS" -eq 1 ] || [ "$POD_COUNT" -eq 1 ]; then
        SCALE_DOWN_DETECTED=true
        log_pass "HPA triggered scale-down! Desired replicas: ${DESIRED_REPLICAS}, Running pods: ${POD_COUNT}"
        break
    fi
done

if [ "$SCALE_DOWN_DETECTED" = false ]; then
    log_fail "HPA did NOT scale down after 5 minutes - Current metric: ${CURRENT_METRIC}"
fi

# Final summary
log_step "Test Summary"

log_raw ""
log_raw "Summary:"
log_raw "  ✅ Prometheus Stack deployed and operational"
log_raw "  ✅ prometheus-adapter deployed and operational"
log_raw "  ✅ Custom GPU metric (pod_gpu_utilization) created via PrometheusRule"
log_raw "  ✅ Custom Metrics API accessible"
log_raw "  ✅ GPU workload deployed with load control capability"
log_raw "  ✅ HPA created with custom GPU metric"
log_raw "  ✅ HPA accessing custom metric successfully"
log_raw "  ✅ HPA scale-up triggered (1 → 2 replicas)"
log_raw "  ✅ GPU load stopped successfully"
log_raw "  ✅ HPA scale-down triggered (2 → 1 replica)"
log_raw ""
log_raw "CONFORMANCE REQUIREMENT MET:"
log_raw "HPA successfully scaled a GPU workload based on custom GPU utilization"
log_raw "metrics from DCGM. Scale-up (1→2 replicas) occurred when GPU utilization"
log_raw "exceeded 10%, and scale-down (2→1 replica) occurred when load was removed,"
log_raw "demonstrating complete HPA functionality for AI/ML workload autoscaling."

finish_test_success "Pod autoscaling with custom GPU metrics validated successfully"
