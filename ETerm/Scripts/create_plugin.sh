#!/bin/bash

# ============================================================================
# Plugin Scaffolding Tool
# ============================================================================
# Creates a new plugin with proper directory structure and manifest.
#
# Usage:
#   create_plugin.sh <name> <type> [options]
#
# Arguments:
#   name    Plugin name (PascalCase)
#   type    Plugin type: rust | swift | custom
#
# Options:
#   --rust-path PATH    Path to Rust project (for rust type)
#   --author NAME       Author name (default: ETerm Team)
#   --description TEXT  Plugin description
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGINS_DIR="${SRCROOT}/Plugins"

# Default values
PLUGIN_NAME=""
PLUGIN_TYPE=""
RUST_PATH=""
AUTHOR="ETerm Team"
DESCRIPTION=""

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Parse arguments
parse_args() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: create_plugin.sh <name> <type> [options]"
        echo ""
        echo "Types: rust, swift, custom"
        echo ""
        echo "Options:"
        echo "  --rust-path PATH    Path to Rust project (for rust type)"
        echo "  --author NAME       Author name"
        echo "  --description TEXT  Plugin description"
        exit 1
    fi

    PLUGIN_NAME="$1"
    PLUGIN_TYPE="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case $1 in
            --rust-path)
                RUST_PATH="$2"
                shift 2
                ;;
            --author)
                AUTHOR="$2"
                shift 2
                ;;
            --description)
                DESCRIPTION="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Validate type
    if [[ ! "$PLUGIN_TYPE" =~ ^(rust|swift|custom)$ ]]; then
        echo "Error: Invalid type '$PLUGIN_TYPE'. Must be: rust, swift, or custom"
        exit 1
    fi

    # Validate name
    if [[ ! "$PLUGIN_NAME" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
        echo "Error: Plugin name must be PascalCase (e.g., MyPlugin)"
        exit 1
    fi
}

# Create Rust plugin
create_rust_plugin() {
    local plugin_dir="$1"

    if [[ -z "$RUST_PATH" ]]; then
        echo "Error: --rust-path required for Rust plugins"
        exit 1
    fi

    cat > "${plugin_dir}/plugin.json" << EOF
{
  "name": "${PLUGIN_NAME}",
  "version": "0.1.0",
  "type": "rust",
  "description": "${DESCRIPTION:-Rust-based plugin}",
  "author": "${AUTHOR}",
  "dependencies": [],

  "build": {
    "enabled": true,
    "rust_project": "${RUST_PATH}",
    "cargo_features": [],
    "cargo_args": [],
    "incremental": true,
    "cache_key": [
      "${RUST_PATH}/src/**/*.rs",
      "${RUST_PATH}/Cargo.toml"
    ]
  },

  "artifacts": [
    {
      "source": "${RUST_PATH}/target/{config}/lib${PLUGIN_NAME,,}.dylib",
      "destination": "Frameworks/lib${PLUGIN_NAME,,}.dylib",
      "type": "dylib",
      "fix_install_name": true
    }
  ],

  "runtime": {
    "auto_load": true,
    "priority": 0
  }
}
EOF

    # Create Swift wrapper
    cat > "${plugin_dir}/Package.swift" << EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "${PLUGIN_NAME}",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "${PLUGIN_NAME}",
            targets: ["${PLUGIN_NAME}"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "${PLUGIN_NAME}",
            dependencies: []
        ),
    ]
)
EOF

    mkdir -p "${plugin_dir}/Sources/${PLUGIN_NAME}"

    cat > "${plugin_dir}/Sources/${PLUGIN_NAME}/${PLUGIN_NAME}.swift" << EOF
import Foundation

@_cdecl("plugin_init")
public func pluginInit() {
    print("[${PLUGIN_NAME}] Plugin initialized")
}

@_cdecl("plugin_deinit")
public func pluginDeinit() {
    print("[${PLUGIN_NAME}] Plugin deinitialized")
}
EOF
}

# Create Swift plugin
create_swift_plugin() {
    local plugin_dir="$1"

    cat > "${plugin_dir}/plugin.json" << EOF
{
  "name": "${PLUGIN_NAME}",
  "version": "0.1.0",
  "type": "swift",
  "description": "${DESCRIPTION:-Pure Swift plugin}",
  "author": "${AUTHOR}",
  "dependencies": [],

  "build": {
    "enabled": true
  },

  "artifacts": [],

  "runtime": {
    "auto_load": true,
    "priority": 0
  }
}
EOF

    cat > "${plugin_dir}/Package.swift" << EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "${PLUGIN_NAME}",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "${PLUGIN_NAME}",
            targets: ["${PLUGIN_NAME}"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "${PLUGIN_NAME}",
            dependencies: []
        ),
    ]
)
EOF

    mkdir -p "${plugin_dir}/Sources/${PLUGIN_NAME}"

    cat > "${plugin_dir}/Sources/${PLUGIN_NAME}/${PLUGIN_NAME}.swift" << EOF
import Foundation

public class ${PLUGIN_NAME} {
    public init() {
        print("[${PLUGIN_NAME}] Initialized")
    }

    public func run() {
        print("[${PLUGIN_NAME}] Running")
    }
}
EOF
}

# Create custom plugin
create_custom_plugin() {
    local plugin_dir="$1"

    cat > "${plugin_dir}/plugin.json" << EOF
{
  "name": "${PLUGIN_NAME}",
  "version": "0.1.0",
  "type": "custom",
  "description": "${DESCRIPTION:-Custom build plugin}",
  "author": "${AUTHOR}",
  "dependencies": [],

  "build": {
    "enabled": true,
    "custom_script": "./build.sh",
    "script_args": [],
    "environment": {},
    "incremental": true,
    "cache_key": [
      "src/**/*"
    ]
  },

  "artifacts": [],

  "runtime": {
    "auto_load": true,
    "priority": 0
  }
}
EOF

    cat > "${plugin_dir}/build.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Building custom plugin..."

# Add your build logic here

echo "Build completed"
EOF

    chmod +x "${plugin_dir}/build.sh"

    mkdir -p "${plugin_dir}/src"
}

# Create README
create_readme() {
    local plugin_dir="$1"

    cat > "${plugin_dir}/README.md" << EOF
# ${PLUGIN_NAME}

${DESCRIPTION}

## Type

${PLUGIN_TYPE}

## Author

${AUTHOR}

## Installation

This plugin is automatically built and loaded by ETerm.

## Development

### Building

\`\`\`bash
cd ${SRCROOT}
./Scripts/build_all_plugins.sh --plugin ${PLUGIN_NAME}
\`\`\`

### Testing

\`\`\`bash
./Scripts/validate_plugin.sh ${PLUGIN_NAME}
\`\`\`

## License

[Your License Here]
EOF
}

# Main
main() {
    parse_args "$@"

    local plugin_dir="${PLUGINS_DIR}/${PLUGIN_NAME}"

    log_info "Creating plugin: $PLUGIN_NAME"
    log_info "Type: $PLUGIN_TYPE"
    log_info "Directory: $plugin_dir"

    # Check if already exists
    if [[ -d "$plugin_dir" ]]; then
        echo "Error: Plugin directory already exists: $plugin_dir"
        exit 1
    fi

    # Create directory
    mkdir -p "$plugin_dir"

    # Create plugin based on type
    case "$PLUGIN_TYPE" in
        rust)
            create_rust_plugin "$plugin_dir"
            ;;
        swift)
            create_swift_plugin "$plugin_dir"
            ;;
        custom)
            create_custom_plugin "$plugin_dir"
            ;;
    esac

    # Create README
    create_readme "$plugin_dir"

    log_success "Plugin created: $plugin_dir"
    echo ""
    log_info "Next steps:"
    echo "  1. Edit ${plugin_dir}/plugin.json to configure your plugin"
    echo "  2. Implement your plugin logic"
    echo "  3. Build: ./Scripts/build_all_plugins.sh --plugin ${PLUGIN_NAME}"
    echo "  4. Validate: ./Scripts/validate_plugin.sh ${PLUGIN_NAME}"
}

main "$@"
