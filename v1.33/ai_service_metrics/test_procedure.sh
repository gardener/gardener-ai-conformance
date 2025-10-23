#!/bin/bash

# AI Service Metrics Conformance Test
# Tests that the platform provides monitoring for AI workload metrics in Prometheus format

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="AI Service Metrics Collection"
TEST_DESCRIPTION="Validates that the platform provides monitoring capable of collecting metrics from AI workloads in Prometheus format"
NAMESPACE="ai-service-metrics"

# Initialize test
init_test

# Check prerequisites
check_kubernetes_access

# Create test namespace
log_step "Setup: Create Test Namespace"
ensure_namespace "${NAMESPACE}"
log_pass "Test namespace created"

# Step 1: Deploy sample AI application with Prometheus metrics
log_step "Step 1: Deploy AI Application with Prometheus Metrics"

log_info "Deploying podinfo as sample AI application (exposes Prometheus metrics)"

cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai-metrics-app
  labels:
    app: ai-metrics-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ai-metrics-app
  template:
    metadata:
      labels:
        app: ai-metrics-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9898"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: podinfo
        image: stefanprodan/podinfo:6.0.0
        ports:
        - name: http
          containerPort: 9898
          protocol: TCP
        - name: grpc
          containerPort: 9999
          protocol: TCP
        env:
        - name: PODINFO_UI_COLOR
          value: "#34577c"
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /healthz
            port: 9898
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /readyz
            port: 9898
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ai-metrics-app
  labels:
    app: ai-metrics-app
spec:
  type: ClusterIP
  selector:
    app: ai-metrics-app
  ports:
  - name: http
    port: 9898
    targetPort: http
    protocol: TCP
  - name: grpc
    port: 9999
    targetPort: grpc
    protocol: TCP
EOF

log_pass "AI application deployed"

# Step 2: Wait for application to be ready
log_step "Step 2: Wait for Application Ready"

if ! wait_for_pod_ready "app=ai-metrics-app" "${NAMESPACE}" "180s"; then
    log_fail "AI application pod failed to become ready"
fi
log_pass "AI application pod is ready"

# Step 3: Deploy Prometheus monitoring stack
log_step "Step 3: Deploy Prometheus Monitoring System"

log_info "Note: Deploying monitoring stack as platform requirement validation"

# Create ServiceAccount
kubectl create serviceaccount prometheus -n "${NAMESPACE}" 2>&1 | tee -a "${LOG_FILE}"

# Create ClusterRole
cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-ai-metrics
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/proxy
  - services
  - endpoints
  - pods
  verbs: ["get", "list", "watch"]
- apiGroups:
  - extensions
  resources:
  - ingresses
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
EOF

add_cleanup_cluster_resource "clusterrole prometheus-ai-metrics"

# Create ClusterRoleBinding
cat <<EOF | kubectl apply -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-ai-metrics
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-ai-metrics
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: ${NAMESPACE}
EOF

add_cleanup_cluster_resource "clusterrolebinding prometheus-ai-metrics"

# Create Prometheus ConfigMap
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${NAMESPACE}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'ai-metrics-app'
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - ${NAMESPACE}
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            target_label: __address__
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: \$1:\$2
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: kubernetes_namespace
          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: kubernetes_pod_name
EOF

# Deploy Prometheus
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - 2>&1 | tee -a "${LOG_FILE}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
  labels:
    app: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
      - name: prometheus
        image: prom/prometheus:v2.45.0
        args:
          - '--config.file=/etc/prometheus/prometheus.yml'
          - '--storage.tsdb.path=/prometheus/'
          - '--storage.tsdb.retention.time=1h'
        ports:
        - name: web
          containerPort: 9090
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: config-volume
          mountPath: /etc/prometheus
        - name: storage-volume
          mountPath: /prometheus
      volumes:
      - name: config-volume
        configMap:
          name: prometheus-config
      - name: storage-volume
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
  labels:
    app: prometheus
spec:
  type: ClusterIP
  selector:
    app: prometheus
  ports:
  - name: web
    port: 9090
    targetPort: web
    protocol: TCP
EOF

log_pass "Prometheus monitoring system deployed"

# Step 4: Wait for Prometheus to be ready
log_step "Step 4: Wait for Prometheus Ready"

if ! wait_for_pod_ready "app=prometheus" "${NAMESPACE}" "180s"; then
    log_fail "Prometheus pod failed to become ready"
fi
log_pass "Prometheus pod is ready"

# Step 5: Generate traffic to application
log_step "Step 5: Generate Application Traffic"

log_info "Generating traffic to create metrics..."

# Port-forward to the application
PF_APP_PID=$(start_port_forward "service/ai-metrics-app" "${NAMESPACE}" 9898 9898)

# Generate traffic
for i in {1..10}; do
    curl -s http://localhost:9898/ >/dev/null 2>&1 || true
    curl -s http://localhost:9898/metrics >/dev/null 2>&1 || true
    sleep 1
done

stop_port_forward "$PF_APP_PID"

log_pass "Traffic generated successfully"

# Wait for metrics to be scraped
log_info "Waiting for Prometheus to scrape metrics (30 seconds)..."
sleep 30

# Step 6: Verify metrics collection
log_step "Step 6: Verify Metrics Collection in Prometheus"

# Port-forward to Prometheus
PF_PROM_PID=$(start_port_forward "service/prometheus" "${NAMESPACE}" 9090 9090)

log_info "Checking Prometheus targets..."
TARGETS_RESPONSE=$(curl -s 'http://localhost:9090/api/v1/targets')
echo "$TARGETS_RESPONSE" >> "${LOG_FILE}"

# Check if our target is up
ACTIVE_TARGETS=$(echo "$TARGETS_RESPONSE" | grep -o '"health":"up"' | wc -l || echo "0")
if [ "$ACTIVE_TARGETS" -gt 0 ]; then
    log_pass "Found ${ACTIVE_TARGETS} active target(s) in Prometheus"
else
    stop_port_forward "$PF_PROM_PID"
    log_fail "No active targets found in Prometheus"
fi

log_info "Querying AI application metrics..."

# Query http_requests_total metric
HTTP_REQUESTS=$(curl -s 'http://localhost:9090/api/v1/query?query=http_requests_total' | grep -o '"result":\[.*\]' || echo "")
echo "http_requests_total query result:" >> "${LOG_FILE}"
echo "$HTTP_REQUESTS" >> "${LOG_FILE}"

# Query version_info metric
VERSION_INFO=$(curl -s 'http://localhost:9090/api/v1/query?query=version_info' | grep -o '"result":\[.*\]' || echo "")
echo "version_info query result:" >> "${LOG_FILE}"
echo "$VERSION_INFO" >> "${LOG_FILE}"

# Check if we got any metrics
if echo "$HTTP_REQUESTS" | grep -q '"result":\[{' || echo "$VERSION_INFO" | grep -q '"result":\[{'; then
    log_pass "Successfully collected metrics from AI application"
else
    stop_port_forward "$PF_PROM_PID"
    log_fail "No metrics collected from AI application"
fi

stop_port_forward "$PF_PROM_PID"

# Final summary
log_step "Test Summary"

log_raw ""
log_raw "Summary:"
log_raw "  ✅ AI application deployed with Prometheus metrics endpoint"
log_raw "  ✅ Prometheus monitoring system deployed and operational"
log_raw "  ✅ Metrics discovery configured via pod annotations"
log_raw "  ✅ Traffic generated to create metrics"
log_raw "  ✅ Prometheus successfully scraped and stored metrics"
log_raw ""
log_raw "Note: This test deploys its own monitoring stack (Prometheus),"
log_raw "therefore the conformance result should be marked as 'Partially Implemented'"
log_raw "in PRODUCT.yaml as the platform does not provide built-in monitoring."
log_raw ""
log_raw "The platform successfully allows deployment and operation of monitoring"
log_raw "solutions capable of discovering and collecting metrics in Prometheus format."

finish_test_success "AI service metrics collection validated - platform supports Prometheus-based monitoring"
