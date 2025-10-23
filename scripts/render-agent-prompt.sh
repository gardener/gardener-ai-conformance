#!/bin/bash

# Script to generate AI Conformance agent prompts
# This script processes prompt.template and generates PROMPT.md files for given Kubernetes version and requirement ID

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

Generate AI Conformance agent prompts for Gardener.

Arguments:
  kubernetes-version    Kubernetes version (e.g., 1.33, 1.34)
  requirement-id        Requirement ID to generate prompt for, or 'all' to generate all prompts for the version

Examples:
  $0 1.33 accelerator_metrics      # Generate prompt for accelerator_metrics for K8s 1.33
  $0 1.33 all                       # Generate prompts for all requirements for K8s 1.33
  $0 1.34 ai_inference              # Generate prompt for ai_inference for K8s 1.34

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
                echo "    (No requirements found)"
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

    # Find all directories that contain REQUIREMENT.md
    find "$version_dir" -maxdepth 2 -name "REQUIREMENT.md" -exec dirname {} \; | \
        xargs -n1 basename | \
        sort
}

# Function to process template and substitute includes and variables
process_template() {
    local kubernetes_version="$1"
    local requirement_id="$2"
    local template_file="resources/prompt.template"

    # Create requirement namespace (with underscores replaced by hyphens)
    local requirement_namespace="${requirement_id//_/-}"
    
    # Export environment variables for substitution
    export KUBERNETES_VERSION="$kubernetes_version"
    export REQUIREMENT_ID="$requirement_id"
    export REQUIREMENT_NAMESPACE="$requirement_namespace"
    local requirement_namespace="${requirement_id//_/-}"
    
    # Process the template with awk to handle includes and variable substitution
    awk -v root="$(pwd)" -v k8s_version="$kubernetes_version" -v req_id="$requirement_id" -v req_namespace="$requirement_namespace" '
    /{{include:/ {
        # Extract the file path from {{include:filepath}}
        gsub(/^.*{{include:/, "", $0);
        gsub(/}}.*$/, "", $0);

        # Replace variables in the include path
        gsub(/\${KUBERNETES_VERSION}/, k8s_version, $0);
        gsub(/\${REQUIREMENT_ID}/, req_id, $0);
        gsub(/\${REQUIREMENT_NAMESPACE}/, req_namespace, $0);

        # Include the file content
        system("cat \"" root "/" $0 "\" 2>/dev/null || echo \"# Error: Could not include file: " $0 "\"");
        next;
    }
    {
        # Replace variables in regular lines
        gsub(/\${KUBERNETES_VERSION}/, k8s_version, $0);
        gsub(/\${REQUIREMENT_ID}/, req_id, $0);
        gsub(/\${REQUIREMENT_NAMESPACE}/, req_namespace, $0);
        print;
    }
    ' "$template_file"
}

# Function to generate a single prompt
generate_prompt() {
    local version="$1"
    local requirement_id="$2"
    local version_dir="v${version}"
    local req_dir="${version_dir}/${requirement_id}"
    local prompt_file="${req_dir}/PROMPT.md"
    local requirement_file="${req_dir}/REQUIREMENT.md"

    if [ ! -d "$req_dir" ]; then
        echo -e "${RED}Error: Requirement directory '${req_dir}' does not exist${NC}" >&2
        echo "Available requirements for v${version}:" >&2
        get_all_requirements "$version" | sed 's|^|  - |' >&2
        return 1
    fi

    if [ ! -f "$requirement_file" ]; then
        echo -e "${RED}Error: Requirement file not found: ${requirement_file}${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Generating prompt: ${requirement_id}${NC}"
    echo -e "${GREEN}Version: v${version}${NC}"
    echo -e "${GREEN}Output: ${prompt_file}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # Process template and generate the prompt
    if process_template "$version" "$requirement_id" > "$prompt_file"; then
        echo -e "${GREEN}✓ Prompt generated successfully: ${prompt_file}${NC}"
        echo "Generated $(wc -l < "$prompt_file") lines"
    else
        echo -e "${RED}✗ Failed to generate prompt: ${prompt_file}${NC}"
        return 1
    fi

    echo ""
    return 0
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

    # Check if template file exists
    if [ ! -f "resources/prompt.template" ]; then
        echo -e "${RED}Error: Template file not found: resources/prompt.template${NC}" >&2
        exit 1
    fi

    # Handle 'all' requirement ID
    if [ "$requirement_id" = "all" ]; then
        echo -e "${GREEN}Generating all prompts for Kubernetes v${k8s_version}${NC}"
        echo ""

        local requirements
        requirements=$(get_all_requirements "$k8s_version")

        if [ -z "$requirements" ]; then
            echo -e "${RED}Error: No requirements found for v${k8s_version}${NC}" >&2
            exit 1
        fi

        local total=0
        local passed=0
        local failed=0
        local failed_prompts=()

        while IFS= read -r req; do
            total=$((total + 1))
            if generate_prompt "$k8s_version" "$req"; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
                failed_prompts+=("$req")
            fi
        done <<< "$requirements"

        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Generation Summary for v${k8s_version}${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo "Total prompts: $total"
        echo -e "${GREEN}Generated: $passed${NC}"
        if [ $failed -gt 0 ]; then
            echo -e "${RED}Failed: $failed${NC}"
            echo "Failed prompts:"
            for prompt in "${failed_prompts[@]}"; do
                echo -e "  ${RED}✗ $prompt${NC}"
            done
        fi
        echo ""

        if [ $failed -gt 0 ]; then
            exit 1
        fi
    else
        # Generate single prompt
        generate_prompt "$k8s_version" "$requirement_id"
        exit $?
    fi
}

# Run main function
main "$@"