# NVIDIA GPU Operator Installation Guide for Gardener

This guide provides step-by-step instructions for installing the NVIDIA GPU Operator on Gardener clusters running Garden Linux, specifically optimized for AI/ML workloads and conformance testing.

## Overview

The NVIDIA GPU Operator automates the management of all NVIDIA software components needed to provision and monitor GPUs in Kubernetes, including:
- NVIDIA drivers
- NVIDIA Container Toolkit
- NVIDIA device plugin for Kubernetes
- NVIDIA DCGM for GPU telemetry
- GPU Feature Discovery
- Node Feature Discovery

## Prerequisites

### Cluster Requirements
- Gardener cluster with GPU-enabled worker nodes (e.g., `g4dn.xlarge` on AWS)
- Kubernetes version 1.21+
- Cluster-admin access
- Helm 3.x installed

### Node Requirements
- Garden Linux OS (requires specific configuration values)
- Sufficient node resources for GPU operator components

## Installation Steps

### Step 1: Add NVIDIA Helm Repository

```bash
# Add the NVIDIA Helm repository
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia

# Update repository information
helm repo update

# Verify repository is added
helm search repo nvidia/gpu-operator
```

### Step 2: Install GPU Operator with Garden Linux Configuration

The key to successful installation on Garden Linux is using the specialized values file that handles the Garden Linux specific requirements:

```bash
# Install GPU Operator with Garden Linux optimized values
helm upgrade --install --create-namespace -n gpu-operator gpu-operator nvidia/gpu-operator --values \
  https://raw.githubusercontent.com/gardenlinux/gardenlinux-nvidia-installer/refs/heads/main/helm/gpu-operator-values.yaml

# Wait for installation to complete
helm status gpu-operator -n gpu-operator
```

### Step 3: Monitor Installation Progress

The GPU operator will deploy several components as DaemonSets and Deployments. Monitor the installation:

```bash
# Watch all pods in gpu-operator namespace
kubectl get pods -n gpu-operator -w

# Check deployment status
kubectl get all -n gpu-operator
```

## Installation Verification

### Step 1: Verify All Pods Are Running

```bash
# Check that all GPU operator pods are running
kubectl get pods -n gpu-operator

# Expected pods (names may vary):
# - gpu-operator-xxxxx (Deployment)
# - gpu-feature-discovery-xxxxx (DaemonSet on GPU nodes)
# - nvidia-container-toolkit-daemonset-xxxxx (DaemonSet on GPU nodes)
# - nvidia-dcgm-exporter-xxxxx (DaemonSet on GPU nodes)
# - nvidia-device-plugin-daemonset-xxxxx (DaemonSet on GPU nodes)
# - nvidia-driver-daemonset-xxxxx (DaemonSet on GPU nodes)
# - nvidia-operator-validator-xxxxx (DaemonSet on GPU nodes)
```

### Step 2: Verify GPU Driver Installation

```bash
# Check driver installation on GPU nodes
kubectl get pods -n gpu-operator -l app=nvidia-driver-daemonset

# Check driver logs
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset --tail=50

# Verify nvidia-smi works on GPU nodes via driver pod
kubectl exec -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}') -- nvidia-smi
```

### Step 3: Verify GPU Resources Are Visible

```bash
# Check that GPU resources are now visible to Kubernetes
kubectl describe nodes | grep -A 10 -B 5 "nvidia.com/gpu"

# Verify GPU resource allocation
kubectl get nodes -o yaml | grep "nvidia.com/gpu"

# Check specific GPU node capacity for all nodes with GPU resources
kubectl get nodes -o jsonpath='{range .items[?(@.status.allocatable.nvidia\.com/gpu)]}{.metadata.name}: {.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

### Step 4: Test GPU Workload Deployment

Deploy a simple GPU test workload to verify everything is working:

```bash
# Create test GPU workload
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  containers:
  - name: gpu-test
    image: nvcr.io/nvidia/cuda:13.0.1-runtime-ubuntu24.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

# Wait for pod to complete and check output
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-test --timeout=300s
kubectl logs gpu-test

# Clean up test pod
kubectl delete pod gpu-test
```

> **Note**: The above test workload simply runs `nvidia-smi` to verify GPU access, which doesn't generate significant GPU load. If you need to test with a workload that actually exercises the GPU (for example, to validate GPU metrics collection or autoscaling), see the alternative test workload in [`v1.33/pod_autoscaling/resources/gpu-workload.yaml`](pod_autoscaling/resources/gpu-workload.yaml). This workload continuously runs CUDA vector addition operations to generate measurable GPU utilization, and is used in the pod autoscaling conformance test (see [`v1.33/pod_autoscaling/test_procedure.sh`](pod_autoscaling/test_procedure.sh)).

## Troubleshooting

### Common Issues

#### Driver Pod Fails to Start
```bash
# Check driver pod logs
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset

# Check node conditions
kubectl describe node <gpu-node> | grep -A 5 Conditions

# Common solutions:
# - Verify Garden Linux values file is used
# - Check node kernel version compatibility
# - Ensure sufficient node resources
# - Verify container runtime configuration
```

#### GPU Resources Not Visible
```bash
# Check device plugin status
kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# Verify GPU hardware detection
kubectl describe node <gpu-node-name> | grep -i gpu

# Check if driver completed successfully first
kubectl get pods -n gpu-operator | grep nvidia-driver
```

#### DCGM Exporter Not Starting
```bash
# Check DCGM exporter status
kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter
kubectl logs -n gpu-operator -l app=nvidia-dcgm-exporter

# DCGM exporter requires driver to be running first
kubectl get pods -n gpu-operator | grep nvidia-driver

# Check initialization dependencies
kubectl describe pod <dcgm-pod> -n gpu-operator
```

#### Components Stuck in Init State
When you see pods in `Init:0/1` or similar states, this usually means they're waiting for the driver installation to complete:

```bash
# This is normal behavior - components wait for driver
kubectl get pods -n gpu-operator
# nvidia-dcgm-exporter-xxxxx      0/1     Init:0/1  0  5m
# nvidia-device-plugin-xxxxx      0/1     Init:0/1  0  5m

# Check init container logs
kubectl logs <pod-name> -n gpu-operator -c <init-container-name>
```

#### Installation Hangs or Takes Too Long
Driver installation can take 5-15 minutes depending on:
- Network speed (downloading driver components)
- Node resources (compilation if needed)
- Garden Linux kernel module compilation

```bash
# Monitor installation progress
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset -f

# Check node resource usage
kubectl top nodes
```

### Debug Commands

```bash
# Check all GPU operator resources
kubectl get all -n gpu-operator

# View events for troubleshooting
kubectl get events -n gpu-operator --sort-by=.metadata.creationTimestamp

# Check node conditions
kubectl describe nodes | grep -A 10 Conditions

# Verify container runtime configuration
kubectl get nodes -o yaml | grep -A 5 -B 5 nvidia
```

## Cleanup

To remove the GPU operator installation:

```bash
# Uninstall GPU operator
helm uninstall gpu-operator -n gpu-operator

# Remove namespace (optional)
kubectl delete namespace gpu-operator

# Verify cleanup
kubectl get pods -A | grep nvidia
```

## Integration with Gardener

### Shoot Configuration

Ensure your Gardener shoot includes GPU worker nodes:

```yaml
spec:
  provider:
    workers:
      - name: worker-gpu
        minimum: 1
        maximum: 3
        machine:
          type: g4dn.xlarge  # AWS GPU instance type
          image:
            name: gardenlinux
            version: "1877.5.0"
        zones:
          - eu-central-1a
```

### Node Labels and Taints

GPU nodes will automatically receive appropriate labels and taints:
- `nvidia.com/gpu.present=true`
- `nvidia.com/gpu.deploy.driver=true`
- Various feature labels from Node Feature Discovery

## Performance Considerations

- **Resource Allocation**: GPU operator components require CPU and memory resources
- **Startup Time**: Driver installation can take 2-5 minutes depending on node specifications
- **Rolling Updates**: Plan for maintenance windows when updating GPU operator versions
- **Monitoring**: Use DCGM Exporter metrics for GPU utilization and health monitoring

## Security Considerations

- GPU operator runs privileged containers for driver installation
- DCGM Exporter exposes detailed hardware metrics
- Consider network policies for metrics endpoints
- Review RBAC permissions for GPU operator service accounts

## Conclusion

Following this guide ensures proper NVIDIA GPU Operator installation on Gardener clusters with Garden Linux. The Garden Linux-specific values file handles the unique requirements of this distribution, enabling successful GPU workload deployment for AI/ML applications and conformance testing.

For additional support, consult:
- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html)
- [Garden Linux NVIDIA Installer Repository](https://github.com/gardenlinux/gardenlinux-nvidia-installer)
- [Gardener Documentation](https://gardener.cloud/docs/)
