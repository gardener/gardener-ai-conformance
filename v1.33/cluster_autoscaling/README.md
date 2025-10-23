# Cluster Autoscaling with GPU Accelerators

## What is Being Tested

**Requirement**: If the platform provides a cluster autoscaler or an equivalent mechanism, it must be able to scale up/down node groups containing specific accelerator types based on pending pods requesting those accelerators.

## How We Tested It

Started with 1 GPU node, deployed 2 pods each requesting 1 GPU (exceeding capacity). Verified autoscaler scaled up to 2 nodes so both pods could run. Then deleted the workload and verified autoscaler scaled back down to 1 node.

## Result

✅ **PASS** - Cluster autoscaler correctly scaled GPU nodes based on pending GPU workloads without requiring nodeAffinity hints.
