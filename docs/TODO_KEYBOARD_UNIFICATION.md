# 快捷键系统统一优化

## 现状问题

当前快捷键绑定有两套实现：

### 内置插件 (PluginContext)
```swift
// 类型: KeyStroke
context.keyboard.bind(.cmd("k"), to: "command.id", when: nil)
```

### SDK 插件 (HostBridge)
```swift
// 类型: KeyboardShortcut
host.bindKeyboard(.cmd("k"), to: "command.id")
```

**问题：**
1. 类型重复定义：`KeyStroke` vs `KeyboardShortcut`
2. 便捷方法重复：`.cmd()`, `.cmdShift()`, `.ctrl()` 等
3. API 不一致：`when` 参数只在内置插件有
4. 命令执行路径不同：直接调用 vs 事件转发

## 依赖分析

### KeyStroke (主程序)
- 依赖 AppKit (NSEvent)
- 依赖 KeyModifiers
- 依赖 Rust FFI (终端序列生成)
- **不能移入 ETermKit**

### KeyboardShortcut (ETermKit)
- 纯数据类型
- Codable (用于 IPC)
- 无外部依赖
- **适合作为公共 API**

## 优化方案

### 分层设计

```
ETermKit (SDK 层)                  ETerm (主程序层)
┌─────────────────────────┐       ┌─────────────────────────┐
│ KeyboardShortcut        │  ←→   │ KeyStroke               │
│ - key: String           │       │ - keyCode: UInt16       │
│ - modifiers: Modifiers  │       │ - character: String?    │
│ - Codable ✓             │       │ - from(NSEvent)         │
│ - .cmd(), .cmdShift()   │       │ - toTerminalSequence()  │
└─────────────────────────┘       └─────────────────────────┘
```

### 实施步骤

1. **统一使用 KeyboardShortcut 作为 API 类型**
   - 内置插件的 `keyboard.bind()` 改为接受 `KeyboardShortcut`
   - 主程序内部需要时转换为 `KeyStroke`

2. **KeyStroke 降级为内部类型**
   - 只用于 NSEvent 处理和终端序列生成
   - 不再暴露给插件层

3. **统一 API**
   ```swift
   // 内置和 SDK 插件都用同一个 API
   keyboard.bind(.cmd("k"), to: "command.id", when: "condition")
   ```

4. **添加 when 条件支持到 SDK**
   - HostBridge.bindKeyboard 增加 when 参数
   - 或者通过 manifest 声明

### 转换实现

```swift
extension KeyStroke {
    init(from shortcut: KeyboardShortcut) {
        self.init(
            keyCode: 0,
            character: shortcut.key.lowercased(),
            actualCharacter: nil,
            modifiers: KeyModifiers(from: shortcut.modifiers)
        )
    }
}
```

## 优先级

低 - 功能已正常工作，这是代码整洁度优化

## 相关文件

- `Packages/ETermKit/Sources/ETermKit/Types/PluginCommand.swift` - KeyboardShortcut 定义
- `ETerm/Core/Keyboard/ValueObjects/KeyStroke.swift` - KeyStroke 定义
- `ETerm/Features/Plugins/ExtensionHost/MainProcessHostBridge.swift` - 转换逻辑
- `ETerm/Core/Keyboard/KeyboardServiceImpl.swift` - 快捷键服务
