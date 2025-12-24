# ETerm Universal Plugin Build System

**One build system to rule them all** - Zero-config plugin addition with automatic discovery, incremental builds, and multi-language support.

## Quick Start

### Create Your First Plugin

```bash
cd /path/to/ETerm

# Create a Rust plugin
./Scripts/create_plugin.sh MyPlugin rust \
  --rust-path "../../path/to/rust-lib" \
  --author "Your Name" \
  --description "My awesome plugin"

# Validate
./Scripts/validate_plugin.sh MyPlugin

# Build
./Scripts/build_all_plugins.sh --plugin MyPlugin

# Done! ✅
```

## What Problem Does This Solve?

### Before

```bash
# Adding a plugin required:
1. Write build script (50 lines of bash)
2. Hardcode paths to external libraries
3. Add Build Phase in Xcode
4. Duplicate install_name fixing logic
5. Hope your friend's machine has the same paths

# Building:
- Always rebuilds (30-60s every time)
- No incremental builds
- Breaks on different machines
```

### After

```bash
# Adding a plugin:
1. Create plugin.json (10 lines)
2. Done!

# Building:
- First build: 30-60s
- Subsequent (no changes): ~1s (cache hit)
- With changes: 5-10s (incremental)
- Works on any machine (relative paths)
```

## Features

- **Zero-Config Addition**: Just create `plugin.json`, no Xcode changes needed
- **Automatic Discovery**: Scans `Plugins/` directory automatically
- **Incremental Builds**: Only rebuilds what changed (10x faster)
- **Multi-Language**: Supports Rust, Swift, and custom build scripts (Node.js, Python, etc.)
- **Dependency Management**: Automatic topological sorting with cycle detection
- **Portable Paths**: Relative path resolution works everywhere
- **Built-in Validation**: Catch errors before building
- **Extensible**: Easy to add new plugin types

## System Architecture

```
Plugins/
├── McpRouterKit/
│   ├── plugin.json          ← Plugin configuration
│   ├── Package.swift         ← Swift package
│   └── Sources/...           ← Source code
├── MyPlugin/
│   ├── plugin.json
│   └── ...
└── ...

Scripts/
├── build_all_plugins.sh     ← Main build script (called by Xcode)
├── create_plugin.sh         ← Create new plugin
└── validate_plugin.sh       ← Validate configuration

Xcode Build Phase:
  Run Script: ./Scripts/build_all_plugins.sh
```

## Documentation

### Quick References

- **[PLUGIN_QUICK_REFERENCE.md](PLUGIN_QUICK_REFERENCE.md)** - One-page cheat sheet ⭐ START HERE
- **[PLUGIN_SYSTEM_OVERVIEW.md](PLUGIN_SYSTEM_OVERVIEW.md)** - High-level overview

### Detailed Guides

- **[PLUGIN_BUILD_GUIDE.md](PLUGIN_BUILD_GUIDE.md)** - Complete build configuration guide
- **[PLUGIN_ARCHITECTURE.md](PLUGIN_ARCHITECTURE.md)** - Deep dive into architecture
- **[PLUGIN_ARCHITECTURE_COMPARISON.md](PLUGIN_ARCHITECTURE_COMPARISON.md)** - Architecture decision rationale

### Reference

- **[PLUGIN_MANIFEST_SCHEMA.json](PLUGIN_MANIFEST_SCHEMA.json)** - JSON Schema for validation
- **[PLUGIN_MANIFEST_EXAMPLES.md](PLUGIN_MANIFEST_EXAMPLES.md)** - Example configurations

### Migration

- **[MIGRATION_MCPROUTER.md](MIGRATION_MCPROUTER.md)** - Real-world migration example

### Runtime Development

- **[PLUGIN_RUNTIME_GUIDE.md](PLUGIN_RUNTIME_GUIDE.md)** - Runtime plugin development (separate from build system)

## Common Use Cases

### Use Case 1: Rust Library with Swift Wrapper

```bash
# Project structure:
ETerm/Plugins/MyPlugin/
  ├── plugin.json
  ├── Package.swift (Swift wrapper)
  └── Sources/...

External:
  ../rust-lib/
    ├── Cargo.toml
    └── src/...

# plugin.json:
{
  "name": "MyPlugin",
  "version": "1.0.0",
  "type": "rust",
  "build": {
    "rust_project": "../../rust-lib"
  },
  "artifacts": [
    {
      "source": "../../rust-lib/target/{config}/librust_lib.dylib",
      "destination": "Frameworks/librust_lib.dylib",
      "fix_install_name": true
    }
  ]
}
```

### Use Case 2: Pure Swift Plugin

```bash
# plugin.json:
{
  "name": "MySwiftPlugin",
  "version": "1.0.0",
  "type": "swift"
}

# That's it! Xcode builds it automatically via Package.swift
```

### Use Case 3: Node.js Addon

```bash
# plugin.json:
{
  "name": "NodePlugin",
  "version": "1.0.0",
  "type": "custom",
  "build": {
    "custom_script": "./build.sh",
    "pre_build": ["npm install", "npm run build"]
  },
  "artifacts": [
    {
      "source": "dist/addon.node",
      "destination": "Resources/addon.node"
    }
  ]
}

# Note: type is "custom", not "nodejs"
# The custom build script handles Node.js-specific build logic
```

### Use Case 4: Plugin with Dependencies

```bash
# plugin.json:
{
  "name": "AdvancedPlugin",
  "version": "1.0.0",
  "type": "swift",
  "dependencies": ["CorePlugin", "UtilsPlugin"]
}

# Build system automatically:
# 1. Builds CorePlugin
# 2. Builds UtilsPlugin
# 3. Builds AdvancedPlugin
```

## Command Reference

### Build Commands

```bash
# Build all plugins
./Scripts/build_all_plugins.sh

# Build one plugin
./Scripts/build_all_plugins.sh --plugin MyPlugin

# Clean build (ignore cache)
./Scripts/build_all_plugins.sh --clean

# Verbose output
./Scripts/build_all_plugins.sh --verbose

# Dry run (show what would be done)
./Scripts/build_all_plugins.sh --dry-run

# Strict mode (fail on first error)
./Scripts/build_all_plugins.sh --strict
```

### Validation Commands

```bash
# Validate all plugins
./Scripts/validate_plugin.sh --all

# Validate one plugin
./Scripts/validate_plugin.sh MyPlugin
```

### Creation Commands

```bash
# Create Swift plugin
./Scripts/create_plugin.sh MyPlugin swift --author "Your Name"

# Create Rust plugin
./Scripts/create_plugin.sh MyPlugin rust \
  --rust-path "../../path/to/rust" \
  --author "Your Name"

# Create custom plugin
./Scripts/create_plugin.sh MyPlugin custom --author "Your Name"
```

## Troubleshooting

### Problem: Build fails with "not found"

```bash
# Solution 1: Check paths with verbose
./Scripts/build_all_plugins.sh --plugin MyPlugin --verbose

# Solution 2: Validate configuration
./Scripts/validate_plugin.sh MyPlugin

# Solution 3: Check plugin.json paths
cat Plugins/MyPlugin/plugin.json | jq -r '.build.rust_project'
```

### Problem: Plugin not rebuilding despite changes

```bash
# Solution: Clear cache and rebuild
rm Plugins/MyPlugin/.build_cache
./Scripts/build_all_plugins.sh --plugin MyPlugin --clean
```

### Problem: Dylib loading error at runtime

```bash
# Check install_name
otool -L build/Debug/ETerm.app/Contents/Frameworks/libmyplugin.dylib

# Should show: @rpath/libmyplugin.dylib

# Fix: Set fix_install_name: true in plugin.json
```

See [PLUGIN_BUILD_GUIDE.md](PLUGIN_BUILD_GUIDE.md) for more troubleshooting.

## Performance

### Build Time Comparison

| Scenario | Old System | New System | Improvement |
|----------|------------|------------|-------------|
| No changes (1 plugin) | 30-60s | ~1s | **30-60x faster** |
| Small change (1 plugin) | 30-60s | 5-10s | **3-6x faster** |
| 10 plugins, 1 changed | ~5 min | ~10s | **30x faster** |

### Cache Effectiveness

```bash
# First build
[INFO] Building Rust plugin: MyPlugin
# Time: 45s

# Second build (no changes)
[VERBOSE] Cache hit for MyPlugin (skipping build)
# Time: <1s

# Third build (changed file)
[INFO] Building Rust plugin: MyPlugin
# Time: 7s (incremental cargo build)
```

## Migration Guide

### Migrating Existing Plugin

See [MIGRATION_MCPROUTER.md](MIGRATION_MCPROUTER.md) for complete walkthrough.

**Summary**:
1. Create `plugin.json` based on existing build script
2. Validate: `./Scripts/validate_plugin.sh MyPlugin`
3. Test: `./Scripts/build_all_plugins.sh --plugin MyPlugin`
4. Remove old Xcode build script
5. Done!

### From Per-Plugin Scripts to Universal System

**Before** (Xcode Build Phases):
```
- Build MCPRouter
- Build Plugin2
- Build Plugin3
```

**After** (Single Build Phase):
```
- Build All Plugins
  Script: ./Scripts/build_all_plugins.sh
```

## FAQ

**Q: Do I need to modify Xcode for each plugin?**

A: No! Just create `Plugins/MyPlugin/plugin.json`. Build system discovers it automatically.

**Q: Can I use absolute paths?**

A: Not recommended. Use relative paths for portability:
```json
{
  "rust_project": "../../external/rust-lib"  // ✅ Good
  "rust_project": "/Users/me/rust-lib"       // ❌ Bad
}
```

**Q: How do I add dependencies between plugins?**

A: Use the `dependencies` field:
```json
{
  "dependencies": ["CorePlugin", "UtilsPlugin"]
}
```

**Q: Can I disable a plugin without deleting it?**

A: Yes:
```json
{
  "build": {
    "enabled": false
  }
}
```

**Q: What if the Rust project is in a separate repo?**

A: Use relative paths:
```json
{
  "rust_project": "../../other-repo/rust-lib"
}
```

**Q: Can I use this for third-party plugins?**

A: Absolutely! Just drop plugin into `Plugins/` with a valid `plugin.json`.

## System Requirements

- macOS 13+
- Xcode 14+
- jq (install with `brew install jq`)

For Rust plugins:
- Rust toolchain

For Node.js plugins:
- Node.js

## Installation

The build system is already included in the ETerm repository:

```bash
cd /path/to/ETerm

# Verify installation
./Scripts/build_all_plugins.sh --help

# Install dependencies
brew install jq
```

## Contributing

### Adding a New Plugin Type

1. Add type to schema: `Docs/PLUGIN_MANIFEST_SCHEMA.json`
2. Add builder function: `Scripts/build_all_plugins.sh`
3. Add validation: `Scripts/validate_plugin.sh`
4. Update documentation

Example:
```bash
# In build_all_plugins.sh:
build_python_plugin() {
    local plugin_name="$1"
    # ... implementation
}

# In main build dispatcher:
case "$plugin_type" in
    rust) build_rust_plugin "$plugin_name" ;;
    swift) build_swift_plugin "$plugin_name" ;;
    python) build_python_plugin "$plugin_name" ;;  # ← New type
    *)
        log_error "Unknown plugin type: $plugin_type"
        return 1
        ;;
esac
```

### Extending the System

The build system is designed to be extended:

- **Custom builders**: Add new plugin types
- **Pre/post processors**: Hook into build pipeline
- **Artifact transformers**: Process artifacts before copying
- **Cache strategies**: Custom cache invalidation

See [PLUGIN_ARCHITECTURE.md](PLUGIN_ARCHITECTURE.md) for details.

## Roadmap

### Phase 1: Core System ✅
- Plugin discovery
- Dependency resolution
- Incremental builds
- Rust/Swift/Custom support
- Validation & scaffolding tools

### Phase 2: Migration 🔄
- Migrate MCPRouter
- Migrate other existing plugins
- Remove old build scripts

### Phase 3: Enhanced Features ⏸
- Plugin registry
- Version constraints
- Hot reload support
- Better error messages

### Phase 4: Ecosystem 📅
- Plugin marketplace UI
- Plugin sandboxing
- Resource bundling
- i18n support

## License

Same as ETerm project.

## Support

- **Documentation**: Start with [PLUGIN_QUICK_REFERENCE.md](PLUGIN_QUICK_REFERENCE.md)
- **Validation**: Run `./Scripts/validate_plugin.sh MyPlugin`
- **Debugging**: Use `--verbose` flag for detailed output
- **Examples**: Check [PLUGIN_MANIFEST_EXAMPLES.md](PLUGIN_MANIFEST_EXAMPLES.md)
- **Issues**: File an issue on GitHub

## Credits

Designed to solve the "朋友构建失败" (friend's build fails) problem - making ETerm plugins portable and easy to build on any machine.

**Key Principle**: Zero-config plugin addition with maximum portability.

---

**Get started**: `./Scripts/create_plugin.sh MyPlugin swift`

**Read more**: [PLUGIN_QUICK_REFERENCE.md](PLUGIN_QUICK_REFERENCE.md)

**Deep dive**: [PLUGIN_ARCHITECTURE.md](PLUGIN_ARCHITECTURE.md)
