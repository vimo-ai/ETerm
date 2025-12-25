#!/bin/bash
# build.sh - Translation Plugin Build Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$SCRIPT_DIR"
KIT_NAME="Translation"

# Configuration from Xcode environment, default to Debug
CONFIGURATION="${CONFIGURATION:-Debug}"

# Output path logic:
# Output to ~/.eterm/plugins/{PluginName}/{PluginName}.bundle
if [ -n "${BUNDLE_OUTPUT_DIR:-}" ]; then
    PLUGIN_DIR="${BUNDLE_OUTPUT_DIR}/${KIT_NAME}"
    mkdir -p "$PLUGIN_DIR"
    OUTPUT_DIR="$PLUGIN_DIR"
else
    OUTPUT_DIR="${KIT_DIR}/build"
fi

BUNDLE_NAME="${KIT_NAME}.bundle"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[${KIT_NAME}]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[${KIT_NAME}]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[${KIT_NAME}]${NC} $*" >&2
}

# Clean and create build directory
rm -rf "$BUNDLE_PATH"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"

log_info "Building Swift package (${CONFIGURATION})..."

# Build Swift package
cd "$KIT_DIR"
if [ "$CONFIGURATION" = "Release" ]; then
    swift build -c release
    SWIFT_BUILD_DIR=".build/release"
else
    swift build
    SWIFT_BUILD_DIR=".build/debug"
fi

# Copy build artifacts
log_info "Packaging bundle..."

# Swift Package product
SWIFT_PRODUCT=""
if [ -f "${SWIFT_BUILD_DIR}/libTranslationKit.dylib" ]; then
    SWIFT_PRODUCT="${SWIFT_BUILD_DIR}/libTranslationKit.dylib"
elif [ -f "${SWIFT_BUILD_DIR}/TranslationKit.dylib" ]; then
    SWIFT_PRODUCT="${SWIFT_BUILD_DIR}/TranslationKit.dylib"
elif [ -f "${SWIFT_BUILD_DIR}/TranslationKit" ]; then
    SWIFT_PRODUCT="${SWIFT_BUILD_DIR}/TranslationKit"
else
    log_error "Build product not found in ${SWIFT_BUILD_DIR}"
    exit 1
fi

cp "$SWIFT_PRODUCT" "${BUNDLE_PATH}/Contents/MacOS/"
log_success "Copied $(basename "$SWIFT_PRODUCT")"

# Copy Info.plist
if [ -f "${KIT_DIR}/Info.plist" ]; then
    cp "${KIT_DIR}/Info.plist" "${BUNDLE_PATH}/Contents/"
    log_success "Copied Info.plist"
fi

# Copy manifest.json
if [ -f "${KIT_DIR}/Resources/manifest.json" ]; then
    cp "${KIT_DIR}/Resources/manifest.json" "${BUNDLE_PATH}/Contents/Resources/"
    log_success "Copied manifest.json"
fi

log_success "Bundle created: ${BUNDLE_PATH}"
