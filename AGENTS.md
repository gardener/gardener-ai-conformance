# Gardener AI Conformance

You are an agent helping implement and execute the test procedures and store the results for certifying Gardener as a CNCF-certified AI Platform. You must be honest, neutral, and fair in determining whether Gardener meets a particular requirement.

## Background Information

### About Gardener

Gardener is an open-source Kubernetes management system for automating the creation, operation, and lifecycle management of Kubernetes clusters as a service. It provides a homogeneous, Kubernetes-native, and extensible way to manage large numbers of clusters across various cloud providers and on-premises infrastructure. The control plane operates outside the cluster and is managed directly by Gardener. You can only access the API server endpoint remotely.

### GPU Access

Gardener runs Garden Linux as operation system. Garden Linux supports the NVIDIA GPU Operator. A test cluster with GPU machines and a pre-deployed NVIDIA GPU Operator is available for the conformance tests. You can assume this setup as given.

### CNCF AI Conformance

The CNCF AI Conformance program defines a set of standards for running AI/ML workloads on Kubernetes. The goal is to ensure interoperability and portability for AI workloads across different Kubernetes platforms.

### Conformance Testing

This repository houses the test plans, procedures, and results for Gardener's AI Conformance certification. The directory structure is organized by Kubernetes version, then requirement ID, with each directory containing the relevant test information.

```
├── v1.33/
    ├── some_requirement_id/        # Requirement (ID)
        ├── REQUIREMENT.md          # Exact requirement as defined by the standards body
        ├── PROMPT.md               # Agent prompt to help with each requirement
        ├── README.md               # Test procedure for humans to reproduce test procedure step-by-step (written by agent)
        ├── test_procedure.sh       # Test procedure script for humans and agents to run (implemented by agent)
        ├── test_result.log         # Test result log (unaltered output of above test procedure script)
    ├── other_requirement_id/       # Other requirement (ID)
    ├── ...
    ├── AIConformance-1.33.yaml     # Template that needs to be filled out (defined by the standards body)
    ├── NVIDIA-GPU-Operator.md      # Instructions how to GPU-enable a cluster (instructions for testers)
    ├── PRODUCT.yaml                # Gardener's self-assessment (will be uploaded to the standards body)
    └── shoot.yaml                  # Gardener `shoot` cluster spec (to be applied by testers)
```
