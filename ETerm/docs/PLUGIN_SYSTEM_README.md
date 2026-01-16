# ETerm 插件构建系统

> 此文档描述构建流程。开发者请参阅 [Plugins/PLUGIN_SDK.md](../../Plugins/PLUGIN_SDK.md)

## 构建流程

```
Plugins/
├── WorkspaceKit/
│   ├── Package.swift
│   ├── build.sh           ← 独立构建
│   └── Resources/manifest.json
├── ...
└── create-plugin.sh       ← 创建新插件

ETerm/Scripts/
├── build_all_plugins.sh   ← Xcode Build Phase 调用
└── package_builtin_plugins.sh  ← 打包内置插件
```

## 构建命令

```bash
# 构建所有插件
./ETerm/Scripts/build_all_plugins.sh

# 构建单个插件
cd Plugins/WorkspaceKit && ./build.sh

# 创建新插件
cd Plugins && ./create-plugin.sh MyPlugin
```

## Xcode 集成

Build Phases 中的 "Build All Plugins" 脚本：
```bash
"${SRCROOT}/Scripts/build_all_plugins.sh"
```

输出位置：
- Debug: 直接安装到 `~/.vimo/eterm/plugins/`
- Release: 打包到 app bundle，启动时自动安装

## 内置插件分发

1. Xcode 构建时打包插件到 `ETerm.app/Contents/PlugIns/`
2. 首次启动 `BuiltinPluginInstaller` 复制到 `~/.vimo/eterm/plugins/`
3. Debug 模式总是覆盖，Release 按版本号比较

## 目录约定

| 位置 | 用途 |
|------|------|
| `Plugins/*Kit/` | 插件源码 |
| `~/.vimo/eterm/plugins/` | 用户安装目录 |
| `ETerm.app/Contents/PlugIns/` | 内置插件 |

## 相关文件

- [Plugins/PLUGIN_SDK.md](../../Plugins/PLUGIN_SDK.md) - 开发者文档
- `ETerm/Application/BuiltinPluginInstaller.swift` - 内置插件安装器
- `ETerm/Scripts/build_all_plugins.sh` - 批量构建脚本
