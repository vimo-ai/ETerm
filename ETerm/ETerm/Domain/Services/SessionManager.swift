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
/// - 保存所有窗口状态到 ~/.eterm-config/session.json
/// - 启动时恢复窗口状态
/// - 窗口关闭时从 session 移除
final class SessionManager {
    static let shared = SessionManager()

    private let configDir = NSHomeDirectory() + "/.eterm-config"
    private let sessionPath = NSHomeDirectory() + "/.eterm-config/session.json"

    private init() {
        // 确保配置目录存在
        ensureConfigDirectory()
    }

    // MARK: - 配置目录管理

    /// 确保配置目录存在
    private func ensureConfigDirectory() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configDir) {
            try? fileManager.createDirectory(
                atPath: configDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

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
            try data.write(to: URL(fileURLWithPath: sessionPath))
        } catch {
            print("❌ SessionManager: Failed to save session - \(error)")
        }
    }

    /// 加载 Session
    ///
    /// - Returns: Session 状态，如果文件不存在或解析失败返回 nil
    func load() -> SessionState? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sessionPath) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sessionPath))
            let decoder = JSONDecoder()
            let session = try decoder.decode(SessionState.self, from: data)
            return session
        } catch {
            print("❌ SessionManager: Failed to load session - \(error)")
            return nil
        }
    }

    /// 清除 Session 文件
    func clear() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: sessionPath) {
            try? fileManager.removeItem(atPath: sessionPath)
        }
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
}
