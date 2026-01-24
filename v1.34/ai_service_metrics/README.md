# AI Service Metrics Collection

## What is Being Tested

**Requirement**: Provide a monitoring system capable of discovering and collecting metrics from workloads that expose them in a standard format (e.g. Prometheus exposition format). This ensures easy integration for collecting key metrics from common AI frameworks and servers.

## How We Tested It

Deployed a test AI application (podinfo) exposing Prometheus metrics, then deployed our own Prometheus stack with pod annotation-based discovery. Generated traffic and verified metrics were successfully scraped and queryable.

## Result

✅ **PASS** - Platform supports running monitoring solutions capable of Prometheus metrics collection. Gardener does not provide built-in monitoring for user workloads; users must deploy their own monitoring stack.
