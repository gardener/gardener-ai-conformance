# Accelerator Metrics Conformance Test

## What is Being Tested

**Requirement**: For supported accelerator types, the platform must allow for the installation and successful operation of at least one accelerator metrics solution that exposes fine-grained performance metrics via a standardized, machine-readable metrics endpoint. This must include a core set of metrics for per-accelerator utilization and memory usage. Additionally, other relevant metrics such as temperature, power draw, and interconnect bandwidth should be exposed if the underlying hardware or virtualization layer makes them available.

## How We Tested It

Verified that NVIDIA DCGM Exporter (pre-installed via GPU Operator) exposes GPU metrics at `http://nvidia-dcgm-exporter.gpu-operator.svc:9400/metrics` in Prometheus format, including per-accelerator utilization, memory, temperature, and power metrics.

## Result

✅ **PASS** - All required metrics available in standardized format with per-GPU granularity.
