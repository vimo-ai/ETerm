# CoreTerminalService 重构计划

> 目标：统一 MCP Tools 和 HostBridge 的终端操作底层，避免重复实现
> 最后更新: 2025-12-30
> 状态: **已完成**

## 一、背景

### 问题起源

VlaudeKit 需要支持三个 WebSocket 写操作事件：
- `server:createSession` - 创建会话
- `server:checkLoading` - 检查加载状态
- `server:sendMessage` - 发送消息

但 HostBridge 缺少 `createTerminalTab` 能力，而 MCP 已有 `open_terminal` Tool。

### 当前架构问题

```
MCP Server
  └── OpenTerminalTool → 直接操作 WindowManager/Coordinator
  └── SendInputTool    → 直接操作 Coordinator

HostBridge (SDK 插件用)
  └── writeToTerminal  → 直接操作 TerminalServiceImpl
  └── 缺少 createTerminalTab
```

重复逻辑：
- 创建终端：OpenTerminalTool 和 HostBridge 各自实现
- 发送输入：SendInputTool 和 HostBridge.writeToTerminal 各自实现

---

## 二、目标架构

```
CoreTerminalService (底层统一实现)
  ├── createTab(cwd:, windowNumber:, panelId:) -> CreateTabResult
  ├── sendInput(terminalId:, text:, pressEnter:) async -> Bool
  └── ... (未来扩展)
        ↑
    ┌───┴───┐
    │       │
MCP Tools   HostBridge
    │       │
OpenTerminalTool.execute()     MainProcessHostBridge.createTerminalTab()
SendInputTool.execute()        MainProcessHostBridge.writeToTerminal()
```

优点：
1. 核心逻辑只实现一次
2. MCP 和 HostBridge 都是"协议适配层"
3. 新增能力时只需在底层添加，然后暴露到两个接口
4. 便于测试和维护

---

## 三、实现步骤

### Phase 1: 创建 CoreTerminalService

**文件**: `ETerm/ETerm/Core/Terminal/Domain/Services/CoreTerminalService.swift`

```swift
import Foundation
import AppKit

/// 核心终端服务
///
/// 提供终端操作的底层统一实现，供 MCP Tools 和 HostBridge 共用。
/// 所有方法都在主线程执行。
@MainActor
enum CoreTerminalService {

    // MARK: - Types

    struct CreateTabResult {
        let success: Bool
        let terminalId: Int?
        let panelId: String?
        let message: String
    }

    struct SendInputResult {
        let success: Bool
        let message: String
    }

    // MARK: - Create Tab

    /// 创建终端 Tab
    ///
    /// - Parameters:
    ///   - cwd: 工作目录（nil 继承当前目录）
    ///   - windowNumber: 指定窗口（nil 使用当前活跃窗口）
    ///   - panelId: 指定 panel（nil 使用当前活跃 panel）
    /// - Returns: 创建结果
    static func createTab(
        cwd: String? = nil,
        windowNumber: Int? = nil,
        panelId: String? = nil
    ) -> CreateTabResult {
        // 抽取自 OpenTerminalTool.addTabToPanel
        // TODO: 实现
    }

    // MARK: - Send Input

    /// 发送输入到终端
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - text: 输入文本
    ///   - pressEnter: 是否追加回车
    /// - Returns: 是否成功
    static func sendInput(
        terminalId: Int,
        text: String,
        pressEnter: Bool = false
    ) async -> SendInputResult {
        // 抽取自 SendInputTool.execute
        // TODO: 实现
    }
}
```

### Phase 2: 重构 MCP Tools

**OpenTerminalTool.swift**:
```swift
case .currentPanel:
    let result = CoreTerminalService.createTab(
        cwd: workingDirectory,
        windowNumber: windowNumber,
        panelId: targetPanelId.uuidString
    )
    return Response(
        success: result.success,
        message: result.message,
        terminalId: result.terminalId,
        panelId: result.panelId
    )
```

**SendInputTool.swift**:
```swift
static func execute(terminalId: Int, text: String, pressEnter: Bool = false) async -> Response {
    let result = await CoreTerminalService.sendInput(
        terminalId: terminalId,
        text: text,
        pressEnter: pressEnter
    )
    return Response(success: result.success, message: result.message)
}
```

### Phase 3: 扩展 HostBridge

**HostBridge.swift** (协议):
```swift
/// 创建终端 Tab
///
/// 在当前窗口的当前 Panel 创建新终端 Tab。
///
/// 需要 capability: `terminal.createTab`
///
/// - Parameter cwd: 工作目录（nil 使用当前目录）
/// - Returns: 新终端的 ID，失败返回 nil
func createTerminalTab(cwd: String?) -> Int?
```

**MainProcessHostBridge.swift**:
```swift
func createTerminalTab(cwd: String?) -> Int? {
    if Thread.isMainThread {
        return CoreTerminalService.createTab(cwd: cwd).terminalId
    } else {
        var result: Int?
        DispatchQueue.main.sync {
            result = CoreTerminalService.createTab(cwd: cwd).terminalId
        }
        return result
    }
}
```

**ExtensionHostBridge.swift** (SDK 插件端):
- VlaudeKit 是 `runMode: main`，直接使用 MainProcessHostBridge，无需 IPC
- 如果未来有 `runMode: extension` 的插件需要，再添加 IPC 支持

### Phase 4: VlaudeKit 事件处理

**VlaudeClient.swift** 新增事件监听:
```swift
// server:createSession
socket.on("server:createSession") { [weak self] data in
    guard let self = self,
          let dict = data.first as? [String: Any],
          let projectPath = dict["projectPath"] as? String else { return }

    let prompt = dict["prompt"] as? String
    let requestId = dict["requestId"] as? String

    self.delegate?.vlaudeClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)
}

// server:sendMessage
socket.on("server:sendMessage") { [weak self] data in
    guard let self = self,
          let dict = data.first as? [String: Any],
          let sessionId = dict["sessionId"] as? String,
          let text = dict["text"] as? String else { return }

    let requestId = dict["requestId"] as? String
    self.delegate?.vlaudeClient(self, didReceiveSendMessage: sessionId, text: text, requestId: requestId)
}

// server:checkLoading
socket.on("server:checkLoading") { [weak self] data in
    guard let self = self,
          let dict = data.first as? [String: Any],
          let sessionId = dict["sessionId"] as? String else { return }

    let requestId = dict["requestId"] as? String
    self.delegate?.vlaudeClient(self, didReceiveCheckLoading: sessionId, requestId: requestId)
}
```

**VlaudePlugin.swift** 实现:
```swift
// MARK: - server:createSession

func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?) {
    guard let host = host else {
        reportSessionCreatedResult(requestId: requestId, success: false, error: "Host not available")
        return
    }

    // 1. 创建终端
    guard let terminalId = host.createTerminalTab(cwd: projectPath) else {
        reportSessionCreatedResult(requestId: requestId, success: false, error: "Failed to create terminal")
        return
    }

    // 2. 启动 Claude
    let command = prompt != nil ? "claude -p \"\(prompt!)\"" : "claude"
    host.writeToTerminal(terminalId: terminalId, data: command + "\n")

    // 3. 等待 session（调用 ClaudeKit 服务）
    DispatchQueue.global().async { [weak self] in
        let result = host.callService(
            pluginId: "com.eterm.claude",
            name: "waitForSession",
            params: ["terminalId": terminalId, "timeout": 30]
        )

        if let result = result,
           let success = result["success"] as? Bool, success,
           let sessionId = result["sessionId"] as? String {
            self?.reportSessionCreatedResult(
                requestId: requestId,
                success: true,
                sessionId: sessionId,
                projectPath: projectPath
            )
        } else {
            let error = (result?["error"] as? String) ?? "Session not started"
            self?.reportSessionCreatedResult(requestId: requestId, success: false, error: error)
        }
    }
}

// MARK: - server:sendMessage

func vlaudeClient(_ client: VlaudeClient, didReceiveSendMessage sessionId: String, text: String, requestId: String?) {
    guard let terminalId = reverseSessionMap[sessionId] else {
        reportSendMessageResult(requestId: requestId, success: false, message: "Session not in ETerm")
        return
    }

    // 写入终端
    host?.writeToTerminal(terminalId: terminalId, data: text)

    // 延迟发送回车
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
        self?.reportSendMessageResult(requestId: requestId, success: true, via: "eterm")
    }
}

// MARK: - server:checkLoading

func vlaudeClient(_ client: VlaudeClient, didReceiveCheckLoading sessionId: String, requestId: String?) {
    guard let terminalId = reverseSessionMap[sessionId] else {
        reportCheckLoadingResult(requestId: requestId, loading: false)
        return
    }

    // 检查是否有 thinking 状态（通过 ClaudeKit 服务）
    // TODO: ClaudeKit 需要新增 isLoading 服务
    // 临时方案：假设有 session 就是 loading
    reportCheckLoadingResult(requestId: requestId, loading: true)
}

// MARK: - Response Helpers

private func reportSessionCreatedResult(requestId: String?, success: Bool, sessionId: String? = nil, projectPath: String? = nil, error: String? = nil) {
    guard let requestId = requestId else { return }

    var data: [String: Any] = [
        "requestId": requestId,
        "success": success
    ]
    if let sessionId = sessionId { data["sessionId"] = sessionId }
    if let projectPath = projectPath { data["projectPath"] = projectPath }
    if let error = error { data["error"] = error }

    client?.emit("daemon:sessionCreatedResult", data)
}

private func reportSendMessageResult(requestId: String?, success: Bool, message: String? = nil, via: String? = nil) {
    guard let requestId = requestId else { return }

    var data: [String: Any] = [
        "requestId": requestId,
        "success": success
    ]
    if let message = message { data["message"] = message }
    if let via = via { data["via"] = via }

    client?.emit("daemon:sendMessageResult", data)
}

private func reportCheckLoadingResult(requestId: String?, loading: Bool) {
    guard let requestId = requestId else { return }

    client?.emit("daemon:checkLoadingResult", [
        "requestId": requestId,
        "loading": loading
    ])
}
```

---

## 四、改动清单

| 文件 | 改动 | 状态 |
|------|------|------|
| `CoreTerminalService.swift` | 新建，底层统一实现 | [x] |
| `OpenTerminalTool.swift` | 调用 CoreTerminalService | [x] |
| `SendInputTool.swift` | 调用 CoreTerminalService | [x] |
| `HostBridge.swift` | 添加 `createTerminalTab(cwd:) -> Int?` | [x] |
| `MainProcessHostBridge.swift` | 实现 `createTerminalTab` | [x] |
| `ExtensionHostBridge.swift` | 实现 `createTerminalTab`（返回 nil） | [x] |
| `VlaudeClient.swift` | 添加三个事件监听 + emit 方法 | [x] |
| `VlaudePlugin.swift` | 实现三个事件处理 + loading 跟踪 | [x] |
| `VlaudeClientDelegate` | 新增三个 delegate 方法 | [x] |
| `manifest.json` | 添加 `claude.promptSubmit` 订阅 | [x] |

### 可选（未来）

| 文件 | 改动 | 状态 |
|------|------|------|
| `IPCMessage.swift` | 添加 `createTerminalTab` 消息类型 | [ ] |
| `PluginIPCBridge.swift` | 处理 `createTerminalTab` IPC | [ ] |
| `ClaudeKit` | 新增 `isLoading` 服务 | [ ] |

---

## 五、测试计划

### 单元测试

1. CoreTerminalService.createTab 返回正确的 terminalId
2. CoreTerminalService.sendInput 正确发送文本
3. MCP Tools 调用 CoreTerminalService 得到相同结果

### 集成测试

1. iOS App 发送 `createSession` → VlaudeKit 创建终端 + 启动 Claude → 返回 sessionId
2. iOS App 发送 `sendMessage` → VlaudeKit 注入文本到终端 → 返回成功
3. iOS App 发送 `checkLoading` → VlaudeKit 返回 loading 状态

---

## 六、相关文档

- [PLAN_DATA_FLOW_REFACTOR.md](../../claude/docs/PLAN_DATA_FLOW_REFACTOR.md) - 数据流重构计划（读写操作 HTTP → WebSocket）
- [ARCHITECTURE_V2.md](./ARCHITECTURE_V2.md) - ETerm 整体架构

---

## 七、进度记录

| 日期 | 进度 |
|------|------|
| 2025-12-30 | 创建文档，确定重构方案 |
| 2025-12-30 | 完成所有 Phase 实现 |

## 八、实现细节

### CoreTerminalService 位置
`ETerm/ETerm/Core/Terminal/Domain/Services/CoreTerminalService.swift`

### 新增事件
- `server:createSession` - 创建会话（新方式）
- `server:sendMessage` - 发送消息
- `server:checkLoading` - 检查 loading 状态

### 响应事件
- `daemon:sessionCreatedResult` - createSession 结果
- `daemon:sendMessageResult` - sendMessage 结果
- `daemon:checkLoadingResult` - checkLoading 结果

### Loading 状态跟踪
- 监听 `claude.promptSubmit` 设置 loading = true
- 监听 `claude.responseComplete` 设置 loading = false
- `loadingSessions: Set<String>` 存储正在思考的 sessionId
