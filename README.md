<p align="center">
  <img src=".github/assets/logo.svg" width="180" alt="ETerm Logo">
</p>

<h1 align="center">ETerm</h1>

<p align="center">
  <strong>The best plugin-friendly terminal for the AI CLI era.</strong>
</p>

<p align="center">
  <a href=".github/README_zh.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange" alt="Swift">
  <img src="https://img.shields.io/badge/Rust-1.75+-red" alt="Rust">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## Features

- **Plugin-first** — Lightweight core, features as plugins, install what you need
- **Local-first** — Your data stays on your machine, sync is optional
- **GPU Rendering** — 60 FPS, Metal accelerated
- **AI CLI Native** — Optimized for Claude Code and similar tools

## Quick Start

```bash
# Clone
git clone --recursive https://github.com/vimo-ai/ETerm.git
cd ETerm

# Build Rust FFI
./scripts/update_sugarloaf_dev.sh

# Open in Xcode and run
open ETerm.xcodeproj  # Cmd+R
```

## Documentation

Visit **[vimo.github.io/docs/eterm](https://vimo.github.io/docs/eterm)** for full documentation.

## License

[MIT](./LICENSE)
