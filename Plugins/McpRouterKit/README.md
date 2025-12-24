# McpRouterKit

MCP Router 的 Swift 桥接库，为 ETerm 提供 MCP Router 功能。

## 概述

McpRouterKit 是一个 Swift Package，封装了 MCP Router Rust Core 的 FFI 接口，提供类型安全的 Swift API。

## 功能特性

- ✅ 类型安全的 Swift API
- ✅ 自动 dylib 加载（多级 fallback）
- ✅ 完整的错误处理
- ✅ 支持 HTTP 和 Stdio 服务器
- ✅ Light/Full 模式切换
- ✅ 服务器配置管理
- ✅ Workspace 支持

## 快速开始

### 安装

1. 将 McpRouterKit 添加为 Local Swift Package
2. 配置 dylib 构建和复制（参见 [集成指南](INTEGRATION_GUIDE.md)）

### 基本使用

```swift
import McpRouterKit

// 初始化日志（应用启动时调用一次）
MCPRouterBridge.initLogging()

// 创建 Router 实例
let router = try MCPRouterBridge()

// 添加服务器
try router.addServer(.http(
    name: "my-server",
    url: "http://localhost:3000",
    description: "My MCP Server"
))

// 启动 HTTP 服务
try router.startServer(port: 19104)

// 查询状态
let status = try router.getStatus()
print("Running: \(status.isRunning)")
print("Servers: \(status.serverCount)")

// 列出所有服务器
let servers = try router.listServers()
for server in servers {
    print("- \(server.name): \(server.enabled ? "enabled" : "disabled")")
}

// 停止服务
try router.stopServer()
```

## API 文档

### MCPRouterBridge

主要桥接类，提供所有 MCP Router 功能。

#### 静态方法

- `initLogging()` - 初始化 Rust 日志系统
- `version` - 获取 Rust Core 版本

#### 实例方法

**服务器管理：**
- `addServer(_ config: MCPServerConfig)` - 添加服务器配置
- `addHTTPServer(name:url:description:)` - 快速添加 HTTP 服务器
- `loadServers(_ configs: [MCPServerConfig])` - 批量加载服务器
- `listServers() -> [MCPServerConfig]` - 列出所有服务器
- `removeServer(name:)` - 移除服务器
- `setServerEnabled(name:enabled:)` - 启用/禁用服务器
- `setServerFlattenMode(name:flatten:)` - 设置平铺模式

**HTTP 服务控制：**
- `startServer(port:)` - 启动 HTTP 服务
- `stopServer()` - 停止 HTTP 服务
- `getStatus() -> MCPRouterStatus` - 获取运行状态

**模式切换：**
- `setExposeManagementTools(_ expose: Bool)` - 设置 Light/Full 模式
- `getExposeManagementTools() -> Bool` - 查询当前模式

**Workspace：**
- `loadWorkspacesFromJSON(_ json: String)` - 加载 Workspace 配置

### MCPServerConfig

服务器配置数据结构。

#### 创建 HTTP 服务器

```swift
let config = MCPServerConfig.http(
    name: "my-http-server",
    url: "http://localhost:3000",
    headers: ["Authorization": "Bearer token"],
    description: "My HTTP MCP Server"
)
```

#### 创建 Stdio 服务器

```swift
let config = MCPServerConfig.stdio(
    name: "my-stdio-server",
    command: "/usr/local/bin/mcp-server",
    args: ["--verbose"],
    env: ["ENV_VAR": "value"],
    description: "My Stdio MCP Server"
)
```

### MCPRouterStatus

Router 运行状态。

```swift
struct MCPRouterStatus {
    let isRunning: Bool
    let serverCount: Int
    let enabledServerCount: Int
}
```

### MCPRouterError

错误类型定义。

```swift
enum MCPRouterError: Error {
    case invalidHandle
    case libraryNotLoaded
    case symbolNotFound(String)
    case operationFailed(String)
    case jsonParsingFailed(String)
}
```

## 项目结构

```
McpRouterKit/
├── Sources/
│   └── McpRouterKit/
│       ├── McpRouterKit.swift      # 主入口和文档
│       ├── MCPRouterBridge.swift   # Rust FFI 桥接
│       ├── MCPServerConfig.swift   # 数据模型
│       └── MCPRouterError.swift    # 错误类型
├── Scripts/
│   ├── build_rust_dylib.sh         # Rust dylib 构建脚本
│   └── validate_dylib.sh           # dylib 验证脚本
├── Tests/
│   └── McpRouterKitTests/
├── Package.swift
├── README.md                        # 本文件
├── IMPLEMENTATION_GUIDE.md         # 实施指南
└── INTEGRATION_GUIDE.md            # ETerm 集成指南
```

## 构建和开发

### 构建 Rust dylib

```bash
# Debug 构建
./Scripts/build_rust_dylib.sh debug

# Release 构建
./Scripts/build_rust_dylib.sh release
```

### 验证 dylib

```bash
./Scripts/validate_dylib.sh ./build/libmcp_router_core.dylib
```

### 运行测试

```bash
swift test
```

## dylib 加载策略

McpRouterKit 使用智能的 dylib 加载策略，按以下优先级搜索：

1. **App Bundle Frameworks 目录**（生产环境）
   - `ETerm.app/Contents/Frameworks/libmcp_router_core.dylib`

2. **Swift Package Bundle Frameworks 目录**（开发环境）
   - 如果 McpRouterKit 作为 Bundle 加载

3. **Rust 项目构建目录**（开发环境 fallback）
   - `/Users/higuaifan/Desktop/vimo/mcp-router/core/target/debug/libmcp_router_core.dylib`
   - `/Users/higuaifan/Desktop/vimo/mcp-router/core/target/release/libmcp_router_core.dylib`

4. **环境变量自定义路径**
   - `MCP_ROUTER_DYLIB_PATH` 环境变量

这种策略确保：
- ✅ 生产环境使用打包的 dylib
- ✅ 开发环境自动 fallback 到本地构建
- ✅ CI/CD 可通过环境变量自定义路径
- ✅ 明确的错误信息和日志

## 集成到 ETerm

详细的集成步骤请参见 [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md)。

主要步骤：
1. 添加 McpRouterKit 为 Local Package Dependency
2. 配置 Build Phases 自动构建和复制 dylib
3. 更新 MCPRouterPlugin.swift 使用 McpRouterKit
4. 测试和验证

## 故障排查

### dylib 加载失败

**检查日志：**
```
[McpRouterKit] Trying to load dylib from: ...
[McpRouterKit] Failed to load library.
```

**解决方案：**
1. 运行 `validate_dylib.sh` 验证 dylib
2. 检查 dylib 是否复制到正确位置
3. 检查 install_name 和 runpath

### 符号未找到

**检查符号：**
```bash
nm -g libmcp_router_core.dylib | grep mcp_router
```

**解决方案：**
1. 确认 Rust FFI 导出正确
2. 重新构建 dylib

更多故障排查信息请参见 [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md#故障排查)。

## 版本兼容性

| McpRouterKit | Rust Core | ETerm | macOS |
|--------------|-----------|-------|-------|
| 1.0.0        | main      | 1.0+  | 12.0+ |

## 路线图

### Week 1（当前）
- ✅ 创建 Swift Package 结构
- ✅ 实现 FFI 桥接
- ✅ 构建和验证脚本
- ✅ 集成文档

### Week 2-3（计划中）
- ⬜ 创建独立 Bundle 架构
- ⬜ 实现动态插件加载
- ⬜ 支持插件热插拔

## 贡献

欢迎贡献！请遵循以下原则：
- 保持类型安全
- 添加单元测试
- 更新文档
- 遵循 Swift 代码规范

## 许可证

[待定]

## 相关链接

- [MCP Router Rust Core](https://github.com/your-org/mcp-router)
- [ETerm](https://github.com/your-org/eterm)
- [集成指南](INTEGRATION_GUIDE.md)
- [实施指南](IMPLEMENTATION_GUIDE.md)

---

**最后更新：** 2025-12-24
