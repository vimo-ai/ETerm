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
    /// 插件数据（namespace -> 插件自己序列化的 JSON 字符串）
    var plugins: [String: String]?

    init(windows: [WindowState], plugins: [String: String]? = nil) {
        self.windows = windows
        self.version = 1
        self.plugins = plugins
    }
}

/// 窗口状态
struct WindowState: Codable {
    let frame: CodableRect  // 窗口位置和大小
    let pages: [PageState]
    let activePageIndex: Int
    let screenIdentifier: String?  // 屏幕唯一标识符（通过 UUID 或屏幕序号）
    let screenFrame: CodableRect?  // 创建时所在屏幕的尺寸（用于验证）
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
    let tabId: String  // UUID string（用于持久化，确保重启后 ID 一致）
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
/// - 管理插件数据的存取
final class SessionManager {
    static let shared = SessionManager()

    private let userDefaults = UserDefaults.standard
    private let sessionKey = "com.eterm.windowSession"

    /// 插件数据缓存（内存中，保存时合并）
    private var pluginDataCache: [String: String] = [:]
    private let pluginLock = NSLock()

    private init() {
        // 启动时加载插件数据到缓存
        if let session = load() {
            pluginDataCache = session.plugins ?? [:]
        }
    }

    // MARK: - Session 保存和加载

    /// 保存 Session
    ///
    /// - Parameter windows: 窗口状态数组
    func save(windows: [WindowState]) {
        pluginLock.lock()
        let plugins = pluginDataCache.isEmpty ? nil : pluginDataCache
        pluginLock.unlock()

        let session = SessionState(windows: windows, plugins: plugins)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(session)
            userDefaults.set(data, forKey: sessionKey)
        } catch {
            // 保存失败时静默处理
        }
    }

    // MARK: - 插件数据 API

    /// 保存插件数据
    ///
    /// - Parameters:
    ///   - namespace: 插件命名空间（如 "claude"）
    ///   - data: 插件自己序列化的 JSON 字符串
    func setPluginData(namespace: String, data: String) {
        pluginLock.lock()
        pluginDataCache[namespace] = data
        pluginLock.unlock()
    }

    /// 获取插件数据
    ///
    /// - Parameter namespace: 插件命名空间
    /// - Returns: 插件数据，不存在返回 nil
    func getPluginData(namespace: String) -> String? {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        return pluginDataCache[namespace]
    }

    /// 移除插件数据
    ///
    /// - Parameter namespace: 插件命名空间
    func removePluginData(namespace: String) {
        pluginLock.lock()
        pluginDataCache.removeValue(forKey: namespace)
        pluginLock.unlock()
    }

    /// 加载 Session
    ///
    /// - Returns: Session 状态，如果不存在或解析失败返回 nil
    func load() -> SessionState? {
        guard let data = userDefaults.data(forKey: sessionKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let session = try decoder.decode(SessionState.self, from: data)
            return session
        } catch {
            return nil
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
