# Pod Autoscaling with Custom GPU Metrics

## What is Being Tested

**Requirement**: If the platform supports the HorizontalPodAutoscaler, it must function correctly for pods utilizing accelerators. This includes the ability to scale these Pods based on custom metrics relevant to AI/ML workloads.

## How We Tested It

Deployed Prometheus stack with DCGM exporter integration, created a custom GPU utilization metric (`pod_gpu_utilization`) via PrometheusRule, deployed prometheus-adapter to expose it via Custom Metrics API, then created an HPA targeting a GPU workload. Verified HPA scaled up when GPU load exceeded threshold and scaled down when load was removed.

## Result

✅ **PASS** - HPA successfully scaled GPU workloads (1→2→1 replicas) based on custom GPU metrics from DCGM.
