#!/bin/bash

# ============================================================================
# Plugin Validation Tool
# ============================================================================
# Validates plugin.json against schema and checks for common issues.
#
# Usage:
#   validate_plugin.sh [plugin_name]
#   validate_plugin.sh --all
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGINS_DIR="${SRCROOT}/Plugins"
SCHEMA_FILE="${SRCROOT}/Docs/PLUGIN_MANIFEST_SCHEMA.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VALIDATION_PASSED=true

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    VALIDATION_PASSED=false
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Check dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required. Install with: brew install jq"
        exit 1
    fi
}

# Validate JSON syntax
validate_json_syntax() {
    local manifest="$1"

    if ! jq empty "$manifest" 2>/dev/null; then
        log_error "Invalid JSON syntax in $manifest"
        return 1
    fi

    return 0
}

# Validate against schema (basic validation)
validate_against_schema() {
    local manifest="$1"
    local plugin_name=$(basename "$(dirname "$manifest")")

    # Check required fields
    local name=$(jq -r '.name // ""' "$manifest")
    local version=$(jq -r '.version // ""' "$manifest")
    local type=$(jq -r '.type // ""' "$manifest")

    if [[ -z "$name" ]]; then
        log_error "Missing required field: name"
    fi

    if [[ -z "$version" ]]; then
        log_error "Missing required field: version"
    fi

    if [[ -z "$type" ]]; then
        log_error "Missing required field: type"
    fi

    # Validate name matches directory
    if [[ "$name" != "$plugin_name" ]]; then
        log_warning "Plugin name '$name' doesn't match directory name '$plugin_name'"
    fi

    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
        log_error "Invalid version format: $version (expected: X.Y.Z)"
    fi

    # Validate type
    local valid_types=("rust" "swift" "nodejs" "python" "custom")
    if [[ ! " ${valid_types[@]} " =~ " ${type} " ]]; then
        log_error "Invalid type: $type (must be one of: ${valid_types[*]})"
    fi

    return 0
}

# Validate Rust plugin specific fields
validate_rust_plugin() {
    local manifest="$1"
    local plugin_dir=$(dirname "$manifest")

    local rust_project=$(jq -r '.build.rust_project // ""' "$manifest")

    if [[ -z "$rust_project" ]]; then
        log_error "Rust plugin missing 'build.rust_project'"
        return 1
    fi

    # Resolve path
    local resolved_path
    if [[ "$rust_project" =~ ^/ ]]; then
        resolved_path="$rust_project"
    elif [[ "$rust_project" =~ ^\.\.?/ ]]; then
        resolved_path="$(cd "$plugin_dir" && cd "$(dirname "$rust_project")" && pwd)/$(basename "$rust_project")"
    else
        resolved_path="${SRCROOT}/${rust_project}"
    fi

    if [[ ! -f "${resolved_path}/Cargo.toml" ]]; then
        log_error "Cargo.toml not found at: ${resolved_path}/Cargo.toml"
    fi

    return 0
}

# Validate custom plugin specific fields
validate_custom_plugin() {
    local manifest="$1"
    local plugin_dir=$(dirname "$manifest")

    local custom_script=$(jq -r '.build.custom_script // ""' "$manifest")

    if [[ -z "$custom_script" ]]; then
        log_error "Custom plugin missing 'build.custom_script'"
        return 1
    fi

    # Resolve path
    local resolved_path
    if [[ "$custom_script" =~ ^/ ]]; then
        resolved_path="$custom_script"
    elif [[ "$custom_script" =~ ^\.\.?/ ]]; then
        resolved_path="$(cd "$plugin_dir" && cd "$(dirname "$custom_script")" && pwd)/$(basename "$custom_script")"
    else
        resolved_path="${SRCROOT}/${custom_script}"
    fi

    if [[ ! -f "$resolved_path" ]]; then
        log_error "Custom script not found at: $resolved_path"
    elif [[ ! -x "$resolved_path" ]]; then
        log_warning "Custom script not executable: $resolved_path"
    fi

    return 0
}

# Validate artifacts
validate_artifacts() {
    local manifest="$1"

    local artifact_count=$(jq -r '.artifacts | length' "$manifest")

    for ((i=0; i<artifact_count; i++)); do
        local source=$(jq -r ".artifacts[$i].source // \"\"" "$manifest")
        local destination=$(jq -r ".artifacts[$i].destination // \"\"" "$manifest")

        if [[ -z "$source" ]]; then
            log_error "Artifact $i missing 'source'"
        fi

        if [[ -z "$destination" ]]; then
            log_error "Artifact $i missing 'destination'"
        fi
    done

    return 0
}

# Validate dependencies
validate_dependencies() {
    local manifest="$1"
    local plugin_name=$(basename "$(dirname "$manifest")")

    local deps=$(jq -r '.dependencies[]? // empty' "$manifest")

    for dep in $deps; do
        if [[ ! -d "${PLUGINS_DIR}/${dep}" ]]; then
            log_error "Dependency not found: $dep"
        elif [[ ! -f "${PLUGINS_DIR}/${dep}/plugin.json" ]]; then
            log_error "Dependency has no plugin.json: $dep"
        fi
    done

    return 0
}

# Validate a single plugin
validate_plugin() {
    local plugin_name="$1"
    local plugin_dir="${PLUGINS_DIR}/${plugin_name}"
    local manifest="${plugin_dir}/plugin.json"

    echo "========================================="
    echo "Validating: $plugin_name"
    echo "========================================="

    if [[ ! -d "$plugin_dir" ]]; then
        log_error "Plugin directory not found: $plugin_dir"
        return 1
    fi

    if [[ ! -f "$manifest" ]]; then
        log_error "plugin.json not found in $plugin_dir"
        return 1
    fi

    # Validate JSON syntax
    validate_json_syntax "$manifest" || return 1

    # Validate against schema
    validate_against_schema "$manifest"

    # Type-specific validation
    local type=$(jq -r '.type' "$manifest")
    case "$type" in
        rust)
            validate_rust_plugin "$manifest"
            ;;
        custom)
            validate_custom_plugin "$manifest"
            ;;
        swift)
            # No additional validation needed
            ;;
    esac

    # Validate artifacts
    validate_artifacts "$manifest"

    # Validate dependencies
    validate_dependencies "$manifest"

    if [[ "$VALIDATION_PASSED" == "true" ]]; then
        log_success "Plugin validation passed: $plugin_name"
    else
        log_error "Plugin validation failed: $plugin_name"
    fi

    echo ""
    return 0
}

# Main
main() {
    check_dependencies

    if [[ $# -eq 0 ]]; then
        echo "Usage: validate_plugin.sh [plugin_name] | --all"
        exit 1
    fi

    if [[ "$1" == "--all" ]]; then
        for plugin_dir in "$PLUGINS_DIR"/*; do
            if [[ -d "$plugin_dir" && -f "${plugin_dir}/plugin.json" ]]; then
                validate_plugin "$(basename "$plugin_dir")"
            fi
        done
    else
        validate_plugin "$1"
    fi

    if [[ "$VALIDATION_PASSED" != "true" ]]; then
        exit 1
    fi
}

main "$@"
