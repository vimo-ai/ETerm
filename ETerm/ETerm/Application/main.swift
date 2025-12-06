//
//  main.swift
//  ETerm
//
//  应用入口点 - 使用 AppKit 完全接管窗口管理
//
//  为什么不用 SwiftUI 的 @main：
//  - SwiftUI 的 WindowGroup 会覆盖窗口配置
//  - borderless 窗口需要自定义 NSWindow 子类才能接收键盘输入
//  - 后续的多窗口和 Page 拖动需要完全控制窗口
//

import AppKit

// 启动应用
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// 激活应用（确保菜单栏可用）
app.setActivationPolicy(.regular)

// 运行主循环
app.run()
