MUST: Support Dynamic Resource Allocation (DRA) APIs to enable more flexible and fine-grained resource requests beyond simple counts.

How we might test it: Verify that all the resource.k8s.io/v1 DRA API resources are enabled.

Note: In Kubernetes v1.33 resource.k8s.io/v1 is not yet available, so the requirement can at best be passed as "Partially Implemented" in Kubernetes v1.33. Mention this accordingly in the final product notes.
