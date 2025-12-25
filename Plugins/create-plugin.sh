#!/bin/bash
# create-plugin.sh - Create a new ETerm plugin from template
#
# Usage: ./create-plugin.sh <PluginName> [plugin-id]
#
# Examples:
#   ./create-plugin.sh ClaudeMonitor              # ID: com.eterm.claude-monitor
#   ./create-plugin.sh MyPlugin com.example.my   # ID: com.example.my

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/_template"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[create-plugin]${NC} $*"; }
log_success() { echo -e "${GREEN}[create-plugin]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[create-plugin]${NC} $*"; }
log_error() { echo -e "${RED}[create-plugin]${NC} $*"; }

usage() {
    echo "Usage: $0 <PluginName> [plugin-id]"
    echo ""
    echo "Arguments:"
    echo "  PluginName    PascalCase plugin name (e.g., ClaudeMonitor)"
    echo "  plugin-id     Optional bundle ID (default: com.eterm.<kebab-case-name>)"
    echo ""
    echo "Examples:"
    echo "  $0 ClaudeMonitor"
    echo "  $0 MyAwesomePlugin com.example.my-plugin"
    exit 1
}

# Convert PascalCase to kebab-case
to_kebab_case() {
    echo "$1" | sed 's/\([A-Z]\)/-\1/g' | sed 's/^-//' | tr '[:upper:]' '[:lower:]'
}

# Validate plugin name (PascalCase)
validate_name() {
    if [[ ! "$1" =~ ^[A-Z][a-zA-Z0-9]+$ ]]; then
        log_error "Plugin name must be PascalCase (e.g., MyPlugin)"
        exit 1
    fi
}

# Main
if [ $# -lt 1 ]; then
    usage
fi

PLUGIN_NAME="$1"
validate_name "$PLUGIN_NAME"

KEBAB_NAME=$(to_kebab_case "$PLUGIN_NAME")
PLUGIN_ID="${2:-com.eterm.${KEBAB_NAME}}"
PRINCIPAL_CLASS="${PLUGIN_NAME}Logic"
DISPLAY_NAME=$(echo "$PLUGIN_NAME" | sed 's/\([A-Z]\)/ \1/g' | sed 's/^ //')

PLUGIN_DIR="${SCRIPT_DIR}/${PLUGIN_NAME}"

log_info "Creating plugin: ${PLUGIN_NAME}"
log_info "  ID: ${PLUGIN_ID}"
log_info "  Principal Class: ${PRINCIPAL_CLASS}"
log_info "  Directory: ${PLUGIN_DIR}"

# Check if already exists
if [ -d "$PLUGIN_DIR" ]; then
    log_error "Directory already exists: ${PLUGIN_DIR}"
    exit 1
fi

# Check template exists
if [ ! -d "$TEMPLATE_DIR" ]; then
    log_error "Template directory not found: ${TEMPLATE_DIR}"
    exit 1
fi

# Copy template
log_info "Copying template..."
cp -r "$TEMPLATE_DIR" "$PLUGIN_DIR"

# Rename source directory
mv "${PLUGIN_DIR}/Sources/__PLUGIN_NAME__" "${PLUGIN_DIR}/Sources/${PLUGIN_NAME}"

# Rename source file
mv "${PLUGIN_DIR}/Sources/${PLUGIN_NAME}/__PLUGIN_NAME__Logic.swift" \
   "${PLUGIN_DIR}/Sources/${PLUGIN_NAME}/${PRINCIPAL_CLASS}.swift"

# Replace placeholders in all files
log_info "Replacing placeholders..."

find "$PLUGIN_DIR" -type f \( -name "*.swift" -o -name "*.json" -o -name "Package.swift" -o -name "build.sh" \) | while read -r file; do
    sed -i '' "s/__PLUGIN_NAME__/${PLUGIN_NAME}/g" "$file"
    sed -i '' "s/__PLUGIN_ID__/${PLUGIN_ID}/g" "$file"
    sed -i '' "s/__PRINCIPAL_CLASS__/${PRINCIPAL_CLASS}/g" "$file"
    sed -i '' "s/__PLUGIN_DISPLAY_NAME__/${DISPLAY_NAME}/g" "$file"
done

# Make build.sh executable
chmod +x "${PLUGIN_DIR}/build.sh"

log_success "Plugin created: ${PLUGIN_DIR}"
echo ""
echo "Next steps:"
echo "  1. Edit ${PLUGIN_DIR}/Sources/${PLUGIN_NAME}/${PRINCIPAL_CLASS}.swift"
echo "  2. Edit ${PLUGIN_DIR}/Resources/manifest.json (add capabilities, commands, etc.)"
echo "  3. Build: cd ${PLUGIN_DIR} && ./build.sh"
echo ""
