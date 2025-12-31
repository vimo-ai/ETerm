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
//  命令行参数：
//  --replay <file>       回放指定的调试会话文件
//  --export-debug        导出当前调试会话并退出
//  --convert-to-test <name>  将调试会话转换为测试用例
//
//  MCP Server：
//  启动时自动在 http://localhost:11218 提供 MCP 服务
//

import AppKit
import Foundation

// MARK: - 命令行参数处理

/// 处理命令行参数
/// - Returns: 是否应该继续正常启动
func handleCommandLineArguments() -> Bool {
    let args = CommandLine.arguments

    // --replay <file>: 回放调试会话
    if let replayIndex = args.firstIndex(of: "--replay"),
       replayIndex + 1 < args.count {
        let filePath = args[replayIndex + 1]
        handleReplayCommand(filePath: filePath)
        return false
    }

    // --export-debug: 导出调试会话
    if args.contains("--export-debug") {
        handleExportDebugCommand()
        return false
    }

    // --convert-to-test <name>: 转换为测试用例
    if let convertIndex = args.firstIndex(of: "--convert-to-test"),
       convertIndex + 1 < args.count {
        let testName = args[convertIndex + 1]
        handleConvertToTestCommand(testName: testName)
        return false
    }

    // --help: 显示帮助
    if args.contains("--help") || args.contains("-h") {
        printUsage()
        return false
    }

    return true
}

/// 打印使用说明
func printUsage() {
    print("""
    ETerm - 终端模拟器

    用法: ETerm [选项]

    选项:
      --replay <file>           回放指定的调试会话文件
      --export-debug            导出当前调试会话到文件
      --convert-to-test <name>  将调试会话转换为测试用例
      --help, -h                显示此帮助信息

    示例:
      ETerm --replay ~/debug_session.json
      ETerm --convert-to-test tab_drag_focus_loss

    MCP Server:
      ETerm 启动时自动在 http://localhost:11218 提供 MCP 服务

    调试会话文件位置: ~/.vimo/eterm/logs/exports/
    """)
}

/// 处理回放命令
func handleReplayCommand(filePath: String) {
    print("正在加载会话: \(filePath)")

    let url = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: filePath) else {
        print("错误: 文件不存在 - \(filePath)")
        exit(1)
    }

    do {
        let session = try SessionReplayer.loadSession(from: url)
        print("会话加载成功:")
        print("  - 事件数量: \(session.events.count)")
        print("  - 开始时间: \(session.startTime)")
        print("  - 系统版本: \(session.systemInfo.osVersion)")

        // 打印事件摘要
        print("\n事件摘要:")
        for (index, event) in session.events.prefix(20).enumerated() {
            print("  #\(index): \(event.event)")
        }

        if session.events.count > 20 {
            print("  ... 还有 \(session.events.count - 20) 个事件")
        }

        // 验证会话
        if let finalState = session.finalState {
            print("\n期望最终状态:")
            print("  - 窗口数量: \(finalState.windowCount)")
            print("  - 焦点元素: \(finalState.focusedElement.map { "\($0)" } ?? "无")")
        }

        print("\n回放功能需要在完整应用环境中运行。")
        print("请使用菜单: 调试 -> 导出调试报告 来导出会话。")

    } catch {
        print("错误: 加载会话失败 - \(error)")
        exit(1)
    }
}

/// 处理导出调试命令
func handleExportDebugCommand() {
    print("正在导出调试会话...")

    // 确保目录存在
    do {
        try ETermPaths.createDirectories()
    } catch {
        print("错误: 创建目录失败 - \(error)")
        exit(1)
    }

    let result = DebugSessionExporter.shared.exportForBugReport()

    if result.success, let path = result.filePath {
        print("导出成功: \(path.path)")
        if let size = result.fileSize {
            print("文件大小: \(size) 字节")
        }
    } else {
        print("导出失败: \(result.error ?? "未知错误")")
        exit(1)
    }
}

/// 处理转换为测试用例命令
func handleConvertToTestCommand(testName: String) {
    print("正在转换为测试用例: \(testName)")

    // 确保目录存在
    do {
        try ETermPaths.createDirectories()
    } catch {
        print("错误: 创建目录失败 - \(error)")
        exit(1)
    }

    let result = DebugSessionExporter.shared.exportAsTestCase(testName: testName)

    if result.success, let path = result.filePath {
        print("转换成功: \(path.path)")

        // 打印生成的代码预览
        if let content = try? String(contentsOf: path, encoding: .utf8) {
            print("\n--- 生成的测试代码 ---")
            print(content.prefix(500))
            if content.count > 500 {
                print("...")
            }
            print("--- 结束 ---")
        }
    } else {
        print("转换失败: \(result.error ?? "未知错误")")
        exit(1)
    }
}

// MARK: - 应用启动

// 忽略 SIGPIPE 信号，避免 socket 写入时崩溃
signal(SIGPIPE, SIG_IGN)

// 处理命令行参数
guard handleCommandLineArguments() else {
    exit(0)
}

// 启动应用
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// 激活应用（确保菜单栏可用）
app.setActivationPolicy(.regular)

// 运行主循环
app.run()
