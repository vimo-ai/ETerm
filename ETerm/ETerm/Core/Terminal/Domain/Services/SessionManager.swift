//
//  SessionManager.swift
//  ETerm
//
//  Session 管理器 - 负责保存和恢复应用窗口状态
//

import Foundation
import AppKit

// MARK: - Session 数据模型

/// Session 状态 - 顶层结构
struct SessionState: Codable {
    let windows: [WindowState]
    let version: Int

    init(windows: [WindowState]) {
        self.windows = windows
        self.version = 1
    }
}

/// 窗口状态
struct WindowState: Codable {
    let frame: CodableRect  // 窗口位置和大小
    let pages: [PageState]
    let activePageIndex: Int
    let screenIdentifier: String?  // 屏幕唯一标识符（通过 UUID 或屏幕序号）
    let screenFrame: CodableRect?  // 创建时所在屏幕的尺寸（用于验证）
    let nextTerminalNumber: Int  // 下一个终端编号（用于恢复计数器）

    // 兼容旧版本的初始化器
    init(frame: CodableRect, pages: [PageState], activePageIndex: Int, screenIdentifier: String? = nil, screenFrame: CodableRect? = nil, nextTerminalNumber: Int = 1) {
        self.frame = frame
        self.pages = pages
        self.activePageIndex = activePageIndex
        self.screenIdentifier = screenIdentifier
        self.screenFrame = screenFrame
        self.nextTerminalNumber = nextTerminalNumber
    }
}

/// Page 状态
struct PageState: Codable {
    let title: String
    let layout: PanelLayoutState
    let activePanelId: String  // UUID string
}

/// Panel 布局状态（递归结构）
///
/// 使用 indirect 关键字支持递归定义
indirect enum PanelLayoutState: Codable {
    /// 叶子节点（Panel）
    case leaf(panelId: String, tabs: [TabState], activeTabIndex: Int)
    /// 水平分割
    case horizontal(ratio: CGFloat, first: PanelLayoutState, second: PanelLayoutState)
    /// 垂直分割
    case vertical(ratio: CGFloat, first: PanelLayoutState, second: PanelLayoutState)
}

/// Tab 状态
struct TabState: Codable {
    let title: String
    let cwd: String  // 工作目录
}

/// Codable 友好的 CGRect
struct CodableRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - SessionManager

/// Session 管理器（单例）
///
/// 职责：
/// - 保存所有窗口状态到 UserDefaults
/// - 启动时恢复窗口状态
/// - 窗口关闭时从 session 移除
final class SessionManager {
    static let shared = SessionManager()

    private let userDefaults = UserDefaults.standard
    private let sessionKey = "com.eterm.windowSession"

    private init() {}

    // MARK: - Session 保存和加载

    /// 保存 Session
    ///
    /// - Parameter windows: 窗口状态数组
    func save(windows: [WindowState]) {
        let session = SessionState(windows: windows)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(session)
            userDefaults.set(data, forKey: sessionKey)
        } catch {
            // 保存失败时静默处理
        }
    }

    /// 加载 Session
    ///
    /// - Returns: Session 状态，如果不存在或解析失败返回 nil
    func load() -> SessionState? {
        print("🔍 [SessionManager] load() called")

        guard let data = userDefaults.data(forKey: sessionKey) else {
            print("❌ [SessionManager] No session data found in UserDefaults")
            return nil
        }

        print("✅ [SessionManager] Found session data: \(data.count) bytes")

        do {
            let decoder = JSONDecoder()
            let session = try decoder.decode(SessionState.self, from: data)
            print("✅ [SessionManager] Successfully decoded session:")
            print("   - Version: \(session.version)")
            print("   - Windows count: \(session.windows.count)")
            for (index, window) in session.windows.enumerated() {
                print("   - Window[\(index)]:")
                print("     - Pages: \(window.pages.count)")
                print("     - Active page index: \(window.activePageIndex)")
                for (pageIndex, page) in window.pages.enumerated() {
                    print("     - Page[\(pageIndex)]: \"\(page.title)\"")
                    printLayoutState(page.layout, indent: "       ")
                }
            }
            return session
        } catch {
            print("❌ [SessionManager] Failed to decode session: \(error)")
            return nil
        }
    }

    /// 递归打印布局状态（用于调试）
    private func printLayoutState(_ layout: PanelLayoutState, indent: String) {
        switch layout {
        case .leaf(let panelId, let tabs, let activeTabIndex):
            print("\(indent)Leaf Panel (\(panelId))")
            print("\(indent)  Tabs: \(tabs.count), Active: \(activeTabIndex)")
            for (index, tab) in tabs.enumerated() {
                print("\(indent)  Tab[\(index)]: \"\(tab.title)\" CWD=\"\(tab.cwd)\"")
            }
        case .horizontal(let ratio, let first, let second):
            print("\(indent)Horizontal Split (ratio: \(ratio))")
            print("\(indent)  First:")
            printLayoutState(first, indent: indent + "    ")
            print("\(indent)  Second:")
            printLayoutState(second, indent: indent + "    ")
        case .vertical(let ratio, let first, let second):
            print("\(indent)Vertical Split (ratio: \(ratio))")
            print("\(indent)  First:")
            printLayoutState(first, indent: indent + "    ")
            print("\(indent)  Second:")
            printLayoutState(second, indent: indent + "    ")
        }
    }

    /// 清除 Session
    func clear() {
        userDefaults.removeObject(forKey: sessionKey)
    }

    // MARK: - 窗口状态更新

    /// 从 Session 中移除指定窗口
    ///
    /// - Parameter windowNumber: 窗口编号
    func removeWindow(_ windowNumber: Int) {
        // 加载当前 session
        guard var session = load() else { return }

        // 移除指定窗口
        // 注意：这里使用 windowNumber 索引可能不准确，实际应该用窗口 ID
        // 但由于我们没有在 WindowState 中保存窗口 ID，这里简化处理
        // TODO: 改进窗口识别机制

        // 简化处理：重新保存所有剩余窗口
        // 这个方法会在 WindowManager 中被调用，传入最新的窗口列表
    }

    // MARK: - 屏幕辅助方法

    /// 获取屏幕的唯一标识符
    ///
    /// - Parameter screen: NSScreen 实例
    /// - Returns: 屏幕标识符字符串
    static func screenIdentifier(for screen: NSScreen) -> String {
        // 使用屏幕的设备描述获取编号
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "screen-\(screenNumber.intValue)"
        }
        // 备选方案：使用屏幕原点坐标
        return "screen-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))"
    }

    /// 根据标识符查找屏幕
    ///
    /// - Parameter identifier: 屏幕标识符
    /// - Returns: 找到的 NSScreen，如果不存在返回主屏幕
    static func findScreen(withIdentifier identifier: String) -> NSScreen {
        // 先尝试精确匹配
        if let screen = NSScreen.screens.first(where: { screenIdentifier(for: $0) == identifier }) {
            return screen
        }
        // 找不到则返回主屏幕
        return NSScreen.main ?? NSScreen.screens.first!
    }
}
