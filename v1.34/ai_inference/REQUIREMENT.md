MUST: Support the Kubernetes Gateway API with an implementation for advanced traffic management for inference services, which enables capabilities like weighted traffic splitting, header-based routing (for OpenAI protocol headers), and optional integration with service meshes.

How we might test it: Verify that all the gateway.networking.k8s.io/v1 Gateway API resources are enabled.
