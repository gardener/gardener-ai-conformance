# Gardener AI Conformance
[![REUSE status](https://api.reuse.software/badge/github.com/gardener/gardener-ai-conformance)](https://api.reuse.software/info/github.com/gardener/gardener-ai-conformance)

This repository contains the test procedures and results for certifying Gardener as a CNCF-certified AI Platform. Gardener is a project of the [NeoNephos Foundation](https://neonephos.org/). Portions of its open-source development have been funded by the European Union through [NextGenerationEU](https://www.8ra.com/).

Gardener is deployed productively by multiple [adopters](https://gardener.cloud/adopter/) who integrate it as a foundational component within their own cloud and platform offerings. The test procedures and results presented here refer exclusively to the open-source Gardener variant. To achieve a representative AI conformance environment, certain additional components and services are provisioned as part of this setup. The conformance status of Gardener-based platforms (e.g., StackIT, MetalStack, or SAP) may differ, depending on their respective managed service extensions and configurations. For such cases, the documentation of the individual platform should be consulted.

## About Gardener

<img align="left" width="80" height="80" src="https://raw.githubusercontent.com/gardener/gardener/refs/heads/master/logo/gardener.svg"> [Gardener](https://gardener.cloud) is an open-source Kubernetes management system for automating the creation, operation, and lifecycle management of Kubernetes clusters as a service. It provides a homogeneous, Kubernetes-native, and extensible way to manage very large numbers of clusters across various cloud providers and on-premises infrastructures.

<img align="left" width="80" height="80" src="https://raw.githubusercontent.com/gardenlinux/gardenlinux/main/logo/gardenlinux-logo-black-text.svg"> Gardener runs [Garden Linux](https://gardenlinux.io) as the premier operating system. Garden Linux is a <a href="https://debian.org/">Debian GNU/Linux</a> derivative that provides small, auditable Linux images. It is highly secure, fully immutable, and CIS compliant. Together with Gardener, it supports [in-place node updates](https://github.com/gardener/gardener/blob/master/docs/usage/shoot-operations/shoot_updates.md#in-place-updates) without replacing the machine itself, which is especially critical with bare-metal and GPU machines.

## AI/ML Workloads on Gardener

Gardener works together with NVIDIA to provide first-class support for NVIDIA GPUs on Gardener clusters. Most importantly, Gardener and Garden Linux natively support the [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator); see the [installation instructions](https://github.com/gardenlinux/gardenlinux-nvidia-installer) for details.

Beyond GPU enablement, we also collaborate on [Grove](https://github.com/ai-dynamo/grove) — a Kubernetes API purpose-built for orchestrating the full spectrum of modern AI/ML workloads on GPU clusters. Grove unifies diverse inference systems — from single-node models to large-scale, disaggregated architectures — under a single declarative API. It provides native support for critical capabilities such as gang scheduling, topology-aware placement, custom startup ordering, and multi-level autoscaling, enabling optimal performance and resource utilization for demanding AI/ML applications.

## CNCF AI Conformance

The [CNCF AI Conformance](https://github.com/cncf/ai-conformance) program defines a set of standards for running AI/ML workloads on Kubernetes. The goal is to ensure interoperability and portability for AI workloads across different Kubernetes platforms.

A platform must be a CNCF-certified Kubernetes distribution before it can be certified as AI-conformant. The specification is detailed in the [CNCF Kubernetes AI Conformance document](https://docs.google.com/document/d/1hXoSdh9FEs13Yde8DivCYjjXyxa7j4J8erjZPEGWuzc).

## Conformance Testing

This repository houses the test plans, procedures, and results for Gardener's AI Conformance certification. The directory structure is organized by Kubernetes version, then requirement ID, with each directory containing the relevant test information.

```
.
├── KUBERETES_VERSION/
│   ├── REQUIREMENT_ID/
│   │   ├── ...
├── ...
```
