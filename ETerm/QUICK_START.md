# 快速开始: Sugarloaf 集成

## 📁 文件清单

```
ETerm/
├── ETerm/
│   ├── SugarloafBridge.h              # C 头文件 (FFI 接口定义)
│   ├── ETerm-Bridging-Header.h        # Swift Bridging Header
│   ├── SugarloafWrapper.swift         # Swift wrapper 类
│   ├── SugarloafView.swift            # SwiftUI View
│   ├── libsugarloaf_ffi.dylib         # 动态库 (15MB)
│   ├── ContentView.swift              # 主界面
│   ├── WordLearningView.swift         # 单词学习
│   ├── SentenceUnderstandingView.swift # 句子理解
│   └── WritingAssistantView.swift     # 写作助手
├── build-sugarloaf.sh                 # 自动构建脚本
├── INTEGRATION_GUIDE.md               # 详细集成指南
└── QUICK_START.md                     # 本文件

sugarloaf-ffi/
├── src/
│   └── lib.rs                         # Rust FFI 实现
├── Cargo.toml
└── rust-toolchain.toml
```

## 🚀 5 分钟配置 Xcode

### 1. 打开项目
```bash
open /Users/higuaifan/Desktop/hi/小工具/english/ETerm/ETerm.xcodeproj
```

### 2. 添加 Bridging Header

**Target → Build Settings** 搜索 "Bridging Header":

```
Objective-C Bridging Header: ETerm/ETerm-Bridging-Header.h
```

### 3. Link 动态库

**Target → Build Phases → Link Binary With Libraries**:

点击 `+` → `Add Other...` → `Add Files...` → 选择:
```
ETerm/libsugarloaf_ffi.dylib
```

### 4. 复制动态库到 App Bundle

**Target → Build Phases** → 点击左上角 `+` → `New Copy Files Phase`:

- **Destination**: Frameworks
- 点击 `+` 添加 `libsugarloaf_ffi.dylib`
- ✅ 勾选 `Code Sign On Copy`

### 5. 配置 Runpath

**Target → Build Settings** 搜索 "Runpath Search Paths":

添加:
```
@executable_path/../Frameworks
@loader_path/../Frameworks
```

## ✅ 验证配置

运行项目 (Cmd+R),应该能看到:

- ✅ 项目正常编译
- ✅ 无 dylib 加载错误
- ✅ 无符号找不到错误

## 🧪 测试 Sugarloaf

修改 `ContentView.swift`,在 TabView 中添加:

```swift
SugarloafView()
    .frame(minWidth: 800, minHeight: 600)
    .tabItem {
        Label("终端", systemImage: "terminal")
    }
```

预期看到:
- 🟢 绿色: "Welcome to ETerm!"
- ⚪ 灰色: "Powered by Sugarloaf"
- 🟡 黄色: "$ "

## 🔧 重新编译 Rust

如果修改了 `sugarloaf-ffi/src/lib.rs`:

```bash
cd /Users/higuaifan/Desktop/hi/小工具/english/ETerm
./build-sugarloaf.sh
```

然后在 Xcode:
- Cmd+Shift+K (Clean Build Folder)
- Cmd+B (Rebuild)

## 📝 API 快速参考

```swift
// 初始化 (在 NSView 中)
let sugarloaf = SugarloafWrapper(
    windowHandle: windowHandle,
    displayHandle: displayHandle,
    width: Float(bounds.width),
    height: Float(bounds.height),
    scale: Float(window.backingScaleFactor),
    fontSize: 16.0
)

// 链式调用
sugarloaf
    .clear()
    .text("$ ", color: (1.0, 1.0, 0.0, 1.0))  // 黄色
    .text("echo 'Hello'", color: (1.0, 1.0, 1.0, 1.0))  // 白色
    .line()
    .text("Hello", color: (0.0, 1.0, 0.0, 1.0))  // 绿色
    .build()
    .render()
```

## ❓ 常见问题

### dylib not loaded

**错误**: `dyld: Library not loaded`

**解决**: 确保完成了步骤 4 (Copy Files Phase)

### Bridging header not found

**错误**: `'SugarloafBridge.h' file not found`

**解决**:
1. 确保文件在项目中
2. 检查 Build Settings 路径是否正确: `ETerm/ETerm-Bridging-Header.h`

### 黑屏或闪退

**检查**:
1. 确保在 window 可用后才初始化 Sugarloaf
2. 查看 Xcode Console 日志
3. 检查 window handle 是否正确

## 📚 下一步

- [ ] 集成 PTY (真正的终端功能)
- [ ] 实现文本选择
- [ ] 连接翻译功能
- [ ] 优化渲染性能

更多详细信息见: `INTEGRATION_GUIDE.md`
