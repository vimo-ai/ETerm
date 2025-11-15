# Sugarloaf 集成指南

## 已完成的工作

### 1. Rust FFI Wrapper (✅ 完成)
- 位置: `../sugarloaf-ffi/`
- 文件:
  - `src/lib.rs` - FFI wrapper 实现
  - `Cargo.toml` - 配置为 cdylib + staticlib
  - `rust-toolchain.toml` - 固定 Rust 版本 1.90

### 2. C 头文件 (✅ 完成)
- 位置: `ETerm/SugarloafBridge.h`
- 定义了所有导出的 C 函数接口

### 3. Swift Wrapper (✅ 完成)
- 位置: `ETerm/SugarloafWrapper.swift`
- 提供了面向 Swift 的友好 API
- 支持链式调用

### 4. SwiftUI View (✅ 完成)
- 位置: `ETerm/SugarloafView.swift`
- `SugarloafNSView` - NSView 实现
- `SugarloafView` - SwiftUI wrapper

### 5. 编译产物 (✅ 完成)
- 位置: `ETerm/libsugarloaf_ffi.dylib` (15MB)
- 已通过构建脚本自动复制

## 下一步: Xcode 项目配置

需要在 Xcode 中完成以下配置:

### 步骤 1: 添加文件到项目

1. 打开 `ETerm.xcodeproj`
2. 将以下文件添加到项目:
   - `SugarloafBridge.h`
   - `SugarloafWrapper.swift`
   - `SugarloafView.swift`
   - `ETerm-Bridging-Header.h`
   - `libsugarloaf_ffi.dylib`

### 步骤 2: 配置 Build Settings

在 Target -> Build Settings 中设置:

```
Objective-C Bridging Header: ETerm/ETerm-Bridging-Header.h
```

### 步骤 3: Link 动态库

在 Target -> Build Phases -> Link Binary With Libraries:

1. 点击 `+` 按钮
2. 选择 `Add Other...` -> `Add Files...`
3. 选择 `libsugarloaf_ffi.dylib`

### 步骤 4: 复制动态库到 App Bundle

在 Target -> Build Phases 中添加新的 "Copy Files" Phase:

1. 点击左上角 `+` -> `New Copy Files Phase`
2. Destination: `Frameworks`
3. 点击 `+` 添加 `libsugarloaf_ffi.dylib`
4. 勾选 `Code Sign On Copy`

### 步骤 5: 配置 Runpath Search Paths

在 Build Settings 中搜索 "Runpath Search Paths":

添加:
```
@executable_path/../Frameworks
@loader_path/../Frameworks
```

## 测试集成

### 方法 1: 在 ContentView 中测试

修改 `ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            // 添加 Sugarloaf 终端 Tab
            SugarloafView()
                .frame(minWidth: 800, minHeight: 600)
                .tabItem {
                    Label("终端", systemImage: "terminal")
                }

            WordLearningView()
                .tabItem {
                    Label("单词学习", systemImage: "book")
                }

            SentenceUnderstandingView()
                .tabItem {
                    Label("句子理解", systemImage: "text.quote")
                }

            WritingAssistantView()
                .tabItem {
                    Label("写作助手", systemImage: "pencil")
                }
        }
    }
}
```

### 方法 2: 创建独立测试窗口

创建 `SugarloafTestView.swift`:

```swift
import SwiftUI

struct SugarloafTestView: View {
    var body: some View {
        VStack {
            Text("Sugarloaf 终端测试")
                .font(.headline)
                .padding()

            SugarloafView()
                .frame(minWidth: 800, minHeight: 600)
                .border(Color.gray)
        }
        .padding()
    }
}

#Preview {
    SugarloafTestView()
}
```

## 预期效果

成功集成后,应该能看到:

1. ✅ 绿色文本: "Welcome to ETerm!"
2. ✅ 灰色文本: "Powered by Sugarloaf"
3. ✅ 黄色提示符: "$ "

## 可能的问题及解决方案

### 问题 1: dylib not loaded
**错误**: `dyld: Library not loaded: libsugarloaf_ffi.dylib`

**解决**: 确保在 Build Phases 中添加了 "Copy Files" phase,并将 dylib 复制到 Frameworks 目录

### 问题 2: Bridging header not found
**错误**: `'SugarloafBridge.h' file not found`

**解决**: 检查 Build Settings 中的 Bridging Header 路径是否正确

### 问题 3: 符号找不到
**错误**: `Undefined symbol: _sugarloaf_new`

**解决**: 确保 dylib 已正确链接到项目

### 问题 4: 窗口渲染失败
**症状**: 黑屏或闪退

**解决**:
- 检查 window handle 是否正确传递
- 确保在 window 可用后才初始化 Sugarloaf
- 查看控制台日志

## 重新编译 Rust 库

如果修改了 Rust 代码,运行:

```bash
cd /path/to/ETerm
./build-sugarloaf.sh
```

然后在 Xcode 中 Clean Build Folder (Cmd+Shift+K) 并重新构建。

## API 使用示例

### 基础用法

```swift
let sugarloaf = SugarloafWrapper(
    windowHandle: windowHandle,
    displayHandle: displayHandle,
    width: 800,
    height: 600,
    scale: 2.0,
    fontSize: 14.0
)

let rtId = sugarloaf.createRichText()

sugarloaf.clearContent()
sugarloaf.addText("Hello", color: (1.0, 1.0, 1.0, 1.0))
sugarloaf.newLine()
sugarloaf.addText("World", color: (0.0, 1.0, 0.0, 1.0))
sugarloaf.buildContent()
sugarloaf.render()
```

### 链式调用

```swift
sugarloaf
    .clear()
    .text("$ ", color: (1.0, 1.0, 0.0, 1.0))
    .text("ls -la", color: (1.0, 1.0, 1.0, 1.0))
    .line()
    .text("total 42", color: (0.8, 0.8, 0.8, 1.0))
    .build()
    .render()
```

## 下一步开发计划

1. ✅ FFI 基础集成
2. ⏳ 在 Xcode 中配置并测试
3. ⏳ 集成 PTY (teletypewriter) 实现真正的终端功能
4. ⏳ 实现文本选择和翻译功能
5. ⏳ 连接三个学习 View 与终端
6. ⏳ 优化渲染性能和用户体验
