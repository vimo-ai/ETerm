<p align="center">
  <img src="assets/logo.svg" width="180" alt="ETerm Logo">
</p>

<h1 align="center">ETerm</h1>

<p align="center">
  <strong>AI CLI 时代，体验最好的插件友好型终端。</strong>
</p>

<p align="center">
  <a href="../README.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange" alt="Swift">
  <img src="https://img.shields.io/badge/Rust-1.75+-red" alt="Rust">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## 特性

- **插件优先** — 核心轻量，功能插件化，按需安装
- **本地优先** — 数据在你手里，同步可选
- **GPU 渲染** — 60 FPS，Metal 加速
- **AI CLI 原生** — 为 Claude Code 等工具优化

## 快速开始

```bash
# 克隆
git clone --recursive https://github.com/vimo-ai/ETerm.git
cd ETerm

# 编译 Rust FFI
./scripts/update_sugarloaf_dev.sh

# 打开 Xcode 运行
open ETerm.xcodeproj  # Cmd+R
```

## 文档

详细文档请访问 **[vimo.github.io/docs/eterm](https://vimo.github.io/docs/eterm)**

## License

[MIT](./LICENSE)
