// TerminalPlaceholder.swift
// ETermKit
//
// 嵌入式终端占位视图

import SwiftUI
import AppKit

/// 嵌入式终端视图工厂
///
/// 主程序需要注入此工厂，提供真正的终端视图实现。
@MainActor
public enum EmbeddedTerminalFactory {
    /// 创建终端视图的工厂函数
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - cwd: 工作目录
    /// - Returns: NSView 实例
    public static var createView: ((_ terminalId: Int, _ cwd: String) -> NSView)?

    /// 用外部 PTY fd 创建终端视图的工厂函数
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - fd: PTY master fd
    ///   - childPid: 子进程 PID
    /// - Returns: NSView 实例
    public static var createViewWithFd: ((_ terminalId: Int, _ fd: Int32, _ childPid: UInt32) -> NSView)?
}

/// 嵌入式终端占位视图
///
/// 用于在插件视图中标记终端渲染位置。主程序会识别此占位符，
/// 并在对应位置渲染真正的终端视图。
///
/// 用法：
/// ```swift
/// let terminalId = host.createEmbeddedTerminal(cwd: "/path/to/project")
///
/// var body: some View {
///     TerminalPlaceholder(terminalId: terminalId, cwd: "/path/to/project")
///         .frame(height: 300)
/// }
/// ```
public struct TerminalPlaceholder: View {
    /// 终端 ID
    public let terminalId: Int

    /// 工作目录
    public let cwd: String

    /// 初始化占位视图
    ///
    /// - Parameters:
    ///   - terminalId: 通过 `host.createEmbeddedTerminal()` 获取的终端 ID
    ///   - cwd: 工作目录
    public init(terminalId: Int, cwd: String = "") {
        self.terminalId = terminalId
        self.cwd = cwd
    }

    public var body: some View {
        if terminalId < 0 {
            // 创建失败状态
            ZStack {
                Color(white: 0.1)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundColor(.orange)
                    Text("终端创建失败")
                        .foregroundColor(.secondary)
                }
            }
        } else if EmbeddedTerminalFactory.createView != nil {
            // 使用工厂创建真正的终端视图
            EmbeddedTerminalViewWrapper(terminalId: terminalId, cwd: cwd)
        } else {
            // 工厂未注入，显示加载状态
            ZStack {
                Color(white: 0.1)
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("终端加载中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// 嵌入终端视图包装器（NSViewRepresentable）
private struct EmbeddedTerminalViewWrapper: NSViewRepresentable {
    let terminalId: Int
    let cwd: String

    func makeNSView(context: Context) -> NSView {
        if let factory = EmbeddedTerminalFactory.createView {
            return factory(terminalId, cwd)
        } else {
            // 返回一个空视图
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            return view
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 无需更新
    }
}
