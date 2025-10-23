MUST: Ensure that access to accelerators from within containers is properly isolated and mediated by the Kubernetes resource management framework (device plugin or DRA) and container runtime, preventing unauthorized access or interference between workloads.

How we might test it:
Deploy a Pod to a node with available accelerators, without requesting accelerator resources in the Pod spec. Execute a command in the Pod to probe for accelerator devices, and the command should fail or report that no accelerator devices are found.
Create two Pods, each is allocated an accelerator resource. Execute a command in one Pod to attempt to access the other Pod’s accelerator, and should be denied.
