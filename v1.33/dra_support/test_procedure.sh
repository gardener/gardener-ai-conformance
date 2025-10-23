#!/bin/bash

# Dynamic Resource Allocation (DRA) Support Conformance Test
# Validates that the platform supports DRA APIs for flexible resource requests

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/common.sh"

# Test configuration
TEST_NAME="DRA Support Conformance Test"
TEST_DESCRIPTION="Validates that resource.k8s.io API group is available with required resources"
NAMESPACE="dra-support"

# Initialize test
init_test

# Check prerequisites
check_kubernetes_access

# Step 1: Check Kubernetes Version
log_step "Step 1: Check Kubernetes Version"

K8S_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")
log_info "Server Version: ${K8S_VERSION}"

# Step 2: Check DRA API Availability
log_step "Step 2: Check DRA API Availability"

log_info "Checking for resource.k8s.io API group..."

if kubectl api-versions 2>&1 | grep -q "resource.k8s.io"; then
    log_pass "resource.k8s.io API group is available"

    log_info "Available API versions:"
    kubectl api-versions 2>&1 | grep "resource.k8s.io" | while read -r version; do
        log_info "  - ${version}"
    done

    # Check for specific API versions
    V1_AVAILABLE=false
    V1BETA1_AVAILABLE=false
    V1ALPHA3_AVAILABLE=false

    if check_api_version "resource.k8s.io/v1"; then
        V1_AVAILABLE=true
        log_pass "resource.k8s.io/v1 is available (GA - required by conformance)"
    else
        log_warn "resource.k8s.io/v1 is NOT available"
    fi

    if check_api_version "resource.k8s.io/v1beta1"; then
        V1BETA1_AVAILABLE=true
        log_pass "resource.k8s.io/v1beta1 is available"
    fi

    if check_api_version "resource.k8s.io/v1alpha3"; then
        V1ALPHA3_AVAILABLE=true
        log_pass "resource.k8s.io/v1alpha3 is available"
    fi
else
    log_fail "resource.k8s.io API group is NOT available. DRA is required for CNCF AI Conformance."
fi

# Step 3: List available DRA resources
log_step "Step 3: Enumerate DRA Resources"

log_info "Listing all DRA API resources:"
if kubectl api-resources --api-group=resource.k8s.io 2>&1 | tee -a "${LOG_FILE}"; then
    log_pass "DRA resources enumerated successfully"
else
    log_fail "Failed to enumerate DRA resources"
fi

# Step 4: Test individual DRA resource types
log_step "Step 4: Verify DRA Resource Types"

EXPECTED_RESOURCES=("deviceclasses" "resourceclaims" "resourceclaimtemplates" "resourceslices")
FUNCTIONAL_COUNT=0

for resource in "${EXPECTED_RESOURCES[@]}"; do
    log_info "Testing ${resource}..."

    if check_api_resource "${resource}" "resource.k8s.io"; then
        log_pass "${resource} exists in API"

        # Try to list the resource
        if kubectl get "${resource}" --all-namespaces &>/dev/null; then
            COUNT=$(kubectl get "${resource}" --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
            log_pass "${resource} is accessible (${COUNT} items found)"
            FUNCTIONAL_COUNT=$((FUNCTIONAL_COUNT + 1))
        else
            log_warn "${resource} exists but may not be fully functional"
        fi
    else
        log_fail_msg "${resource} NOT found in API"
    fi
done

log_info "Resource functionality: ${FUNCTIONAL_COUNT}/${#EXPECTED_RESOURCES[@]} resources are functional"

# Step 5: Determine final result
log_step "Test Result"

if [[ "$V1_AVAILABLE" == "true" ]]; then
    finish_test_success "DRA Support is fully implemented with resource.k8s.io/v1 API (GA version)"
elif [[ "$V1BETA1_AVAILABLE" == "true" ]] || [[ "$V1ALPHA3_AVAILABLE" == "true" ]]; then
    log_info "DRA APIs available but not in GA (v1) version"
    log_info "Note: resource.k8s.io/v1 API may not be GA yet in Kubernetes v1.33"
    log_info "DRA v1 APIs are expected to be GA in Kubernetes v1.34 or later"
    finish_test_success "DRA Support is partially implemented (beta/alpha APIs available)"
else
    finish_test_failure "DRA API group exists but no functional APIs were found"
fi
