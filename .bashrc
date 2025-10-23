#!/bin/bash

# absolute path to the root of the project
AI_CONFORMANCE_ROOT_PATH="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"

# convenience aliases and useful functions
function target-cluster() {
    if [[ $(cat $KUBECONFIG 2> /dev/null) != *ai-conformance.core.shoot.canary* ]]; then
        gardenctl target canary/core/ai-conformance &&
        kubectl config set-context --current --namespace=default
    else
        echo "Already targeted to ai-conformance cluster."
    fi
}
function target-control-plane() {
    gardenctl target --control-plane canary/core/ai-conformance
}
function watch-resources() {
    local resources=("$@")
    local all_resources=("namespaces")
    local sorted_resources=($(printf '%s\n' "${resources[@]}" | grep -v -E '^(namespaces|nodes)$' | sort -u))
    all_resources+=("${sorted_resources[@]}")
    all_resources+=("nodes")
    local resource_list=$(IFS=','; echo "${all_resources[*]}")
    target-cluster
    watch "kubectl get --all-namespaces ${resource_list} -o wide | grep -v -E 'kube-node-lease|kube-public|kube-system|gpu-operator'"
}
function watch-machines() {
    target-control-plane
    watch "kubectl get machinedeployments,machinesets,machines -o wide"
}

# target cluster
target-cluster 2> /dev/null || echo "Warning: Could not target the ai-conformance cluster. Please ensure that gardenctl is installed, and configured correctly, and the ai-conformance cluster is created, and up."
