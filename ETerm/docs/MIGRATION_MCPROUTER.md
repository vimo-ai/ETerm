# Migrating MCPRouter to Universal Build System

Step-by-step guide to migrate MCPRouter from hardcoded build script to the universal plugin build system.

## Current State

**Build Phase Script** (`ETerm/ETerm.xcodeproj` → Build Phases):
```bash
#!/bin/bash
set -e

MCPROUTER_DIR="${SRCROOT}/Plugins/McpRouterKit"
RUST_PROJECT="${MCPROUTER_DIR}/../../vimo/mcp-router/core"

if [ ! -d "$RUST_PROJECT" ]; then
    echo "⚠️ Warning: Rust project not found at $RUST_PROJECT"
    exit 0
fi

cd "$RUST_PROJECT"

if [ "$CONFIGURATION" == "Release" ]; then
    PROFILE="release"
else
    PROFILE="debug"
fi

cargo build --release || cargo build

DYLIB_PATH="${RUST_PROJECT}/target/${PROFILE}/libmcp_router_core.dylib"

if [ ! -f "$DYLIB_PATH" ]; then
    DYLIB_PATH="${RUST_PROJECT}/target/release/libmcp_router_core.dylib"
fi

DEST_DIR="${BUILT_PRODUCTS_DIR}/ETerm.app/Contents/Frameworks"
mkdir -p "$DEST_DIR"

if [ -f "$DYLIB_PATH" ]; then
    cp "$DYLIB_PATH" "$DEST_DIR/"
    install_name_tool -id "@rpath/libmcp_router_core.dylib" \
        "$DEST_DIR/libmcp_router_core.dylib"
else
    echo "❌ Error: dylib not found"
    exit 1
fi
```

**Problems**:
1. Hardcoded path to `../../vimo/mcp-router/core`
2. No incremental build support
3. Cannot be reused for other plugins
4. No validation
5. Difficult for collaborators (path may not exist on their machine)

## Migration Steps

### Step 1: Create plugin.json

Create `Plugins/McpRouterKit/plugin.json`:

```json
{
  "name": "McpRouterKit",
  "version": "1.0.0",
  "type": "rust",
  "description": "MCP Router plugin for multi-server management",
  "author": "ETerm Team",
  "dependencies": [],

  "build": {
    "enabled": true,
    "rust_project": "../../vimo/mcp-router/core",
    "cargo_features": [],
    "cargo_args": [],
    "incremental": true,
    "cache_key": [
      "../../vimo/mcp-router/core/src/**/*.rs",
      "../../vimo/mcp-router/core/Cargo.toml",
      "../../vimo/mcp-router/core/Cargo.lock"
    ]
  },

  "artifacts": [
    {
      "source": "../../vimo/mcp-router/core/target/{config}/libmcp_router_core.dylib",
      "destination": "Frameworks/libmcp_router_core.dylib",
      "type": "dylib",
      "fix_install_name": true,
      "code_sign": false,
      "strip": false,
      "optional": false
    }
  ],

  "runtime": {
    "auto_load": true,
    "priority": 10
  }
}
```

**Key changes**:
- `rust_project`: Same relative path, now configured
- `cache_key`: Tracks Rust source files for incremental builds
- `artifacts.source`: Uses `{config}` placeholder for Debug/Release
- `fix_install_name`: true (same as old script)

### Step 2: Validate Configuration

```bash
cd /path/to/ETerm

# Validate plugin.json
./Scripts/validate_plugin.sh McpRouterKit

# Expected output:
# =========================================
# Validating: McpRouterKit
# =========================================
# [SUCCESS] Plugin validation passed: McpRouterKit
```

### Step 3: Test Build

```bash
# Build only McpRouterKit
./Scripts/build_all_plugins.sh --plugin McpRouterKit --verbose

# Expected output:
# [INFO] ========================================
# [INFO] Plugin: McpRouterKit
# [INFO] ========================================
# [INFO] Building Rust plugin: McpRouterKit
# [VERBOSE] Executing: cargo build --manifest-path .../Cargo.toml
# [SUCCESS] Rust build completed: McpRouterKit
# [INFO] Copying artifacts for McpRouterKit
# [VERBOSE] Copying: libmcp_router_core.dylib -> Frameworks/libmcp_router_core.dylib
# [VERBOSE] Fixing install_name for: libmcp_router_core.dylib
# [SUCCESS] Artifacts copied: McpRouterKit
# [SUCCESS] Plugin built successfully: McpRouterKit
```

### Step 4: Verify Artifact

```bash
# Check dylib was copied
ls -l build/Debug/ETerm.app/Contents/Frameworks/libmcp_router_core.dylib

# Verify install_name
otool -L build/Debug/ETerm.app/Contents/Frameworks/libmcp_router_core.dylib

# Expected output:
# libmcp_router_core.dylib:
#     @rpath/libmcp_router_core.dylib (...)
#     /usr/lib/libSystem.B.dylib (...)
```

### Step 5: Update Xcode Build Phase

**Remove old build script**:
1. Open `ETerm.xcodeproj` in Xcode
2. Select ETerm target
3. Go to Build Phases
4. Find "Run Script" phase for MCPRouter
5. Delete it

**Add universal build script** (if not already present):
1. Click "+" → "New Run Script Phase"
2. Rename to "Build All Plugins"
3. Add script:
   ```bash
   #!/bin/bash
   set -e
   "${SRCROOT}/Scripts/build_all_plugins.sh"
   ```
4. Move phase before "Compile Sources" (optional)

### Step 6: Clean Build

```bash
# Clean Xcode build
xcodebuild -scheme ETerm clean

# Clean plugin cache
rm -f Plugins/McpRouterKit/.build_cache

# Build from Xcode
xcodebuild -scheme ETerm -configuration Debug

# Or build in Xcode UI
```

### Step 7: Test Runtime

```bash
# Run app
open build/Debug/ETerm.app

# Check console for plugin loading
# Should see MCP Router functionality working
```

## Verification Checklist

- [ ] plugin.json created and validated
- [ ] Test build succeeds with `build_all_plugins.sh`
- [ ] Dylib exists in `Frameworks/`
- [ ] install_name is `@rpath/libmcp_router_core.dylib`
- [ ] Old build script removed from Xcode
- [ ] Universal build script added to Xcode
- [ ] Clean build from Xcode succeeds
- [ ] App runs and MCP Router works

## Benefits After Migration

### 1. Incremental Builds

**Before**:
```bash
# Always rebuilds, even if nothing changed
# Build time: ~30-60s every time
```

**After**:
```bash
# First build: ~30-60s
# Subsequent builds (no changes): ~1s (cache hit)
# Build with changes: ~5-10s (incremental Rust build)
```

### 2. Portability

**Before**:
```bash
# Friend clones repo
# Build fails: "Rust project not found at ../../vimo/mcp-router/core"
# Friend has to manually fix hardcoded path
```

**After**:
```bash
# Friend clones repo (with vimo/ in same parent directory)
# Build succeeds automatically
# Relative path resolves correctly
```

### 3. Validation

**Before**:
```bash
# No way to check if configuration is correct
# Errors only appear during Xcode build
```

**After**:
```bash
./Scripts/validate_plugin.sh McpRouterKit
# Checks:
# - JSON syntax
# - Required fields
# - Rust project exists
# - Artifact paths
```

### 4. Extensibility

**Before**:
```bash
# Want to add another Rust plugin?
# Copy-paste build script
# Modify hardcoded paths
# Add another Build Phase
```

**After**:
```bash
# Create plugin.json
# Done! Build system handles it automatically
```

### 5. Debugging

**Before**:
```bash
# Build fails
# Check Xcode build log
# Scroll through to find error
```

**After**:
```bash
./Scripts/build_all_plugins.sh --plugin McpRouterKit --verbose
# Clear, structured output
# Easy to see what failed
```

## Rollback Plan

If migration causes issues:

### Option 1: Temporarily Disable

```json
{
  "build": {
    "enabled": false  // Disable in universal system
  }
}
```

Then re-add old build script to Xcode.

### Option 2: Full Rollback

```bash
# Delete plugin.json
rm Plugins/McpRouterKit/plugin.json

# Re-add old Build Phase script in Xcode
# Remove universal build script Build Phase
```

## Common Issues

### Issue 1: Rust project not found

**Error**:
```
[ERROR] Cargo.toml not found: /path/to/vimo/mcp-router/core/Cargo.toml
```

**Solution**:
```bash
# Check path in plugin.json
cat Plugins/McpRouterKit/plugin.json | jq -r '.build.rust_project'

# Verify it exists relative to SRCROOT
ls ../../vimo/mcp-router/core/Cargo.toml

# Or use absolute path temporarily
{
  "rust_project": "/Users/you/vimo/mcp-router/core"  // Not recommended
}
```

### Issue 2: Dylib not found after build

**Error**:
```
[ERROR] Artifact not found: .../target/debug/libmcp_router_core.dylib
```

**Solution**:
```bash
# Check if cargo build succeeded
cd ../../vimo/mcp-router/core
cargo build

# Check where dylib actually is
find target -name "libmcp_router_core.dylib"

# Update artifact source path in plugin.json
```

### Issue 3: Cache not working

**Symptom**: Always rebuilds despite no changes

**Solution**:
```bash
# Check cache file
cat Plugins/McpRouterKit/.build_cache

# Try clean build
rm Plugins/McpRouterKit/.build_cache
./Scripts/build_all_plugins.sh --plugin McpRouterKit

# Check cache_key patterns in plugin.json
# Make sure they match actual source files
```

## Next Steps

After successful MCPRouter migration:

1. **Migrate other plugins**: Apply same process to any other plugins with custom build scripts

2. **Add new plugins easily**:
   ```bash
   ./Scripts/create_plugin.sh MyNewPlugin rust \
     --rust-path "../../path/to/rust" \
     --author "Your Name"
   ```

3. **Improve build performance**:
   ```bash
   # Build only changed plugins during development
   ./Scripts/build_all_plugins.sh --plugin ActivePlugin

   # Try parallel builds
   ./Scripts/build_all_plugins.sh --parallel
   ```

4. **Set up CI/CD**:
   ```yaml
   - name: Build Plugins
     run: ./Scripts/build_all_plugins.sh --strict
   ```

## Support

If you encounter issues during migration:

1. Check validation: `./Scripts/validate_plugin.sh McpRouterKit`
2. Try verbose build: `./Scripts/build_all_plugins.sh --plugin McpRouterKit --verbose`
3. Check [Architecture Documentation](PLUGIN_ARCHITECTURE.md)
4. Check [Build Guide](PLUGIN_BUILD_GUIDE.md)
