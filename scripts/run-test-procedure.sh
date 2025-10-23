#!/bin/bash

# Script to run AI Conformance test procedures
# This script executes test_procedure.sh for a given Kubernetes version and requirement ID

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    cat << EOF
Usage: $0 <kubernetes-version> <requirement-id>

Run AI Conformance test procedures for Gardener.

Arguments:
  kubernetes-version    Kubernetes version (e.g., 1.33, 1.34)
  requirement-id        Requirement ID to test, or 'all' to run all tests for the version

Examples:
  $0 1.33 accelerator_metrics      # Run accelerator_metrics test for K8s 1.33
  $0 1.33 all                       # Run all tests for K8s 1.33
  $0 1.34 ai_inference              # Run ai_inference test for K8s 1.34

Available versions:
EOF

    # Dynamically list available versions
    for version_dir in v*/; do
        if [ -d "$version_dir" ]; then
            version=$(echo "$version_dir" | sed 's|v||' | sed 's|/||')
            echo "  - $version"
        fi
    done

    echo ""
    echo "Available requirement IDs:"

    # Dynamically show requirements for each version
    for version_dir in v*/; do
        if [ -d "$version_dir" ]; then
            version=$(echo "$version_dir" | sed 's|v||' | sed 's|/||')
            echo "  For v${version}:"
            if requirements=$(get_all_requirements "$version" 2>/dev/null); then
                echo "$requirements" | sed 's|^|    - |'
            else
                echo "    (No test procedures found)"
            fi
            echo ""
        fi
    done
}

# Function to check if directory exists
check_version_exists() {
    local version="$1"
    local version_dir="v${version}"

    if [ ! -d "$version_dir" ]; then
        echo -e "${RED}Error: Version directory '${version_dir}' does not exist${NC}" >&2
        echo "Available versions:" >&2
        ls -d v*/ 2>/dev/null | sed 's|/||' | sed 's|^|  - |' >&2
        return 1
    fi
    return 0
}

# Function to get all requirement IDs for a version
get_all_requirements() {
    local version="$1"
    local version_dir="v${version}"

    # Find all directories that contain test_procedure.sh
    find "$version_dir" -maxdepth 2 -name "test_procedure.sh" -exec dirname {} \; | \
        xargs -n1 basename | \
        sort
}

# Function to run a single test procedure
run_test_procedure() {
    local version="$1"
    local requirement_id="$2"
    local version_dir="v${version}"
    local test_dir="${version_dir}/${requirement_id}"
    local test_script="${test_dir}/test_procedure.sh"

    if [ ! -d "$test_dir" ]; then
        echo -e "${RED}Error: Requirement directory '${test_dir}' does not exist${NC}" >&2
        echo "Available requirements for v${version}:" >&2
        get_all_requirements "$version" | sed 's|^|  - |' >&2
        return 1
    fi

    if [ ! -f "$test_script" ]; then
        echo -e "${RED}Error: Test procedure script not found: ${test_script}${NC}" >&2
        return 1
    fi

    if [ ! -x "$test_script" ]; then
        echo -e "${YELLOW}Warning: Test script is not executable, making it executable...${NC}"
        chmod +x "$test_script"
    fi

    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}🚀 Running test: ${requirement_id}${NC}"
    echo -e "${GREEN}   Version: v${version}${NC}"
    echo -e "${GREEN}   Script: ${test_script}${NC}"
    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Change to the test directory and run the script
    (cd "$test_dir" && bash test_procedure.sh)
    local exit_code=$?

    echo ""
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Test completed successfully: ${requirement_id}${NC}"
    else
        echo -e "${RED}✗ Test failed: ${requirement_id} (exit code: ${exit_code})${NC}"
    fi
    echo ""

    return $exit_code
}

# Main script logic
main() {
    # Check if help is requested or no arguments provided
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi

    # Check if correct number of arguments
    if [ $# -ne 2 ]; then
        echo -e "${RED}Error: Invalid number of arguments${NC}" >&2
        echo "" >&2
        show_help
        exit 1
    fi

    local k8s_version="$1"
    local requirement_id="$2"

    # Validate kubernetes version format (should be like 1.33, 1.34, etc.)
    if ! [[ "$k8s_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Error: Invalid Kubernetes version format: ${k8s_version}${NC}" >&2
        echo "Version should be in format X.Y (e.g., 1.33, 1.34)" >&2
        exit 1
    fi

    # Check if version directory exists
    if ! check_version_exists "$k8s_version"; then
        exit 1
    fi

    # Handle 'all' requirement ID
    if [ "$requirement_id" = "all" ]; then
        echo -e "${GREEN}Running all test procedures for Kubernetes v${k8s_version}${NC}"
        echo ""

        local requirements
        requirements=$(get_all_requirements "$k8s_version")

        if [ -z "$requirements" ]; then
            echo -e "${RED}Error: No test procedures found for v${k8s_version}${NC}" >&2
            exit 1
        fi

        local total=0
        local passed=0
        local failed=0
        local failed_tests=()

        while IFS= read -r req; do
            total=$((total + 1))
            if run_test_procedure "$k8s_version" "$req"; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
                failed_tests+=("$req")
            fi
        done <<< "$requirements"

        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Test Summary for v${k8s_version}${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo "Total tests: $total"
        echo -e "${GREEN}Passed: $passed${NC}"
        if [ $failed -gt 0 ]; then
            echo -e "${RED}Failed: $failed${NC}"
            echo "Failed tests:"
            for test in "${failed_tests[@]}"; do
                echo -e "  ${RED}✗ $test${NC}"
            done
        fi
        echo ""

        if [ $failed -gt 0 ]; then
            exit 1
        fi
    else
        # Run single test procedure
        run_test_procedure "$k8s_version" "$requirement_id"
        exit $?
    fi
}

# Run main function
main "$@"
