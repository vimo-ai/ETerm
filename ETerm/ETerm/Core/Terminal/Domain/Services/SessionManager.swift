//
//  SessionManager.swift
//  ETerm
//
//  Session 管理器 - 负责保存和恢复应用窗口状态（JSON 文件存储）
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

/// Tab 内容类型
///
/// 用于区分不同类型的 Tab 内容
enum TabContentType: String, Codable {
    case terminal = "terminal"
    case view = "view"

    // 扩展点：未来可添加更多类型
    // case editor = "editor"
    // case log = "log"
}

/// Tab 状态
///
/// 重构说明（2025/12）：
/// - 添加 contentType 字段支持多种内容类型
/// - 旧 session 无此字段时默认为 terminal
/// - cwd 仅对 terminal 类型有意义
/// - userTitle 用于保存用户手动重命名的标题（最高优先级）
/// - pluginTitle 用于保存插件设置的标题（次优先级，如 Claude 会话标题）
struct TabState: Codable {
    let tabId: String  // UUID string（用于持久化，确保重启后 ID 一致）
    let title: String
    let cwd: String  // 工作目录（仅 terminal 类型使用）

    /// 用户手动设置的标题（最高优先级，可选）
    ///
    /// 向后兼容：旧 session 无此字段时为 nil
    let userTitle: String?

    /// 插件设置的标题（次优先级，可选）
    ///
    /// 用于保存插件设置的标题，如 Claude 会话标题。
    /// 向后兼容：旧 session 无此字段时为 nil
    let pluginTitle: String?

    /// Tab 内容类型
    ///
    /// 可选字段，向后兼容：旧 session 无此字段时默认为 terminal
    let contentType: TabContentType?

    /// View Tab 专用字段（可选）
    let viewId: String?
    let pluginId: String?

    // MARK: - 便捷构造器

    /// 创建终端 Tab 状态
    init(tabId: String, title: String, cwd: String, userTitle: String? = nil, pluginTitle: String? = nil) {
        self.tabId = tabId
        self.title = title
        self.cwd = cwd
        self.userTitle = userTitle
        self.pluginTitle = pluginTitle
        self.contentType = .terminal
        self.viewId = nil
        self.pluginId = nil
    }

    /// 创建 View Tab 状态
    init(tabId: String, title: String, viewId: String, pluginId: String? = nil, userTitle: String? = nil, pluginTitle: String? = nil) {
        self.tabId = tabId
        self.title = title
        self.cwd = ""  // View Tab 不需要 cwd
        self.userTitle = userTitle
        self.pluginTitle = pluginTitle
        self.contentType = .view
        self.viewId = viewId
        self.pluginId = pluginId
    }

    // MARK: - 类型判断

    /// 解析后的内容类型（处理向后兼容）
    var resolvedContentType: TabContentType {
        return contentType ?? .terminal
    }

    /// 是否为终端 Tab
    var isTerminal: Bool {
        return resolvedContentType == .terminal
    }

    /// 是否为 View Tab
    var isView: Bool {
        return resolvedContentType == .view
    }
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
/// - 保存所有窗口状态到 JSON 文件
/// - 启动时恢复窗口状态
/// - 窗口关闭时从 session 移除
/// - 管理插件数据的存取
/// - 提供备份和恢复保护机制
final class SessionManager {
    static let shared = SessionManager()

    private let sessionFilePath = ETermPaths.sessionConfig

    /// 备份文件保留数量
    private let maxBackupCount = 5

    /// 插件数据缓存（内存中，保存时合并）
    private var pluginDataCache: [String: String] = [:]
    private let pluginLock = NSLock()

    /// 上次成功保存的窗口数量（用于检测异常）
    private var lastSavedWindowCount: Int = 0

    private init() {
        // 启动时加载插件数据到缓存
        if let session = load() {
            pluginDataCache = session.plugins ?? [:]
        } else if let migratedSession = migrateFromUserDefaults() {
            // MARK: - Migration (TODO: Remove after v1.1)
            // 从旧的 UserDefaults 迁移数据
            pluginDataCache = migratedSession.plugins ?? [:]
            save(windows: migratedSession.windows)
        }
    }

    // MARK: - Session 保存和加载

    /// 保存 Session（带备份和保护机制）
    ///
    /// - Parameters:
    ///   - windows: 窗口状态数组
    ///   - createBackup: 是否创建备份（默认 false）
    ///
    /// 备份时机说明：
    /// - `true`: 有意义的变化（新增/删除 tab/panel/page/window、应用启动/关闭）
    /// - `false`: 位置调整（窗口移动/调整大小、panel 分隔比例变化）
    ///
    /// 保护机制：
    /// 1. 空数据保护：如果 windows 为空且文件已存在，拒绝覆盖
    /// 2. 原子写入：使用临时文件+重命名确保写入完整性
    func save(windows: [WindowState], createBackup: Bool = false) {
        let fileManager = FileManager.default
        let fileExists = fileManager.fileExists(atPath: sessionFilePath)

        // 空数据保护：如果 windows 为空且文件已存在，拒绝覆盖
        if windows.isEmpty && fileExists {
            logWarn("Session 保存被阻止：windows 为空，拒绝覆盖现有 session 文件")
            return
        }

        // 异常检测：窗口数量骤降可能是异常
        if lastSavedWindowCount > 0 && windows.count == 0 {
            logWarn("Session 保存被阻止：窗口数量从 \(lastSavedWindowCount) 骤降到 0，可能是异常")
            return
        }

        pluginLock.lock()
        let plugins = pluginDataCache.isEmpty ? nil : pluginDataCache
        pluginLock.unlock()

        let session = SessionState(windows: windows, plugins: plugins)

        do {
            // 确保父目录存在
            try ETermPaths.ensureParentDirectory(for: sessionFilePath)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)

            // 只在有意义的变化时创建备份
            if createBackup && fileExists {
                try self.createBackup()
            }

            // 使用原子写入
            let tempPath = sessionFilePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tempPath))

            // 原子替换
            if fileExists {
                try fileManager.removeItem(atPath: sessionFilePath)
            }
            try fileManager.moveItem(atPath: tempPath, toPath: sessionFilePath)

            // 更新上次保存的窗口数量
            lastSavedWindowCount = windows.count
        } catch {
            logError("保存 Session 失败: \(error)")
        }
    }

    // MARK: - 备份机制

    /// 创建备份（轮转机制）
    ///
    /// 保留最近 N 个备份，格式：session.json.bak.1, session.json.bak.2, ...
    /// 数字越小越新
    private func createBackup() throws {
        let fileManager = FileManager.default

        // 删除最旧的备份（如果超过限制）
        let oldestPath = "\(sessionFilePath).bak.\(maxBackupCount)"
        if fileManager.fileExists(atPath: oldestPath) {
            try fileManager.removeItem(atPath: oldestPath)
        }

        // 轮转备份：N-1 -> N, N-2 -> N-1, ..., 1 -> 2
        for i in stride(from: maxBackupCount - 1, through: 1, by: -1) {
            let sourcePath = "\(sessionFilePath).bak.\(i)"
            let destPath = "\(sessionFilePath).bak.\(i + 1)"
            if fileManager.fileExists(atPath: sourcePath) {
                try fileManager.moveItem(atPath: sourcePath, toPath: destPath)
            }
        }

        // 当前文件 -> bak.1
        let latestBackupPath = "\(sessionFilePath).bak.1"
        try fileManager.copyItem(atPath: sessionFilePath, toPath: latestBackupPath)
    }

    /// 获取所有备份文件路径（按时间从新到旧）
    func listBackups() -> [String] {
        var backups: [String] = []
        for i in 1...maxBackupCount {
            let backupPath = "\(sessionFilePath).bak.\(i)"
            if FileManager.default.fileExists(atPath: backupPath) {
                backups.append(backupPath)
            }
        }
        return backups
    }

    /// 从备份恢复
    ///
    /// - Parameter backupIndex: 备份索引（1 = 最新，5 = 最旧）
    /// - Returns: 是否恢复成功
    @discardableResult
    func restoreFromBackup(index: Int) -> Bool {
        guard index >= 1 && index <= maxBackupCount else {
            logError("无效的备份索引: \(index)")
            return false
        }

        let backupPath = "\(sessionFilePath).bak.\(index)"
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: backupPath) else {
            logError("备份文件不存在: \(backupPath)")
            return false
        }

        do {
            // 先验证备份文件是否有效
            let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
            let _ = try JSONDecoder().decode(SessionState.self, from: data)

            // 验证通过，执行恢复
            if fileManager.fileExists(atPath: sessionFilePath) {
                try fileManager.removeItem(atPath: sessionFilePath)
            }
            try fileManager.copyItem(atPath: backupPath, toPath: sessionFilePath)

            logInfo("从备份恢复成功: \(backupPath)")
            return true
        } catch {
            logError("从备份恢复失败: \(error)")
            return false
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

    /// 加载 Session（带自动恢复机制）
    ///
    /// - Returns: Session 状态，如果不存在或解析失败返回 nil
    ///
    /// 恢复机制：
    /// 1. 尝试加载主文件
    /// 2. 如果主文件损坏，自动尝试从最新备份恢复
    /// 3. 记录详细日志便于排查问题
    func load() -> SessionState? {
        guard FileManager.default.fileExists(atPath: sessionFilePath) else {
            logInfo("Session 文件不存在，将创建新 session")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sessionFilePath))
            let decoder = JSONDecoder()
            let session = try decoder.decode(SessionState.self, from: data)

            // 记录成功加载的信息
            logInfo("Session 加载成功：\(session.windows.count) 个窗口")
            lastSavedWindowCount = session.windows.count

            return session
        } catch {
            logError("加载 Session 失败: \(error)")

            // 尝试从备份恢复
            logWarn("主 Session 文件损坏，尝试从备份恢复...")
            if let restoredSession = tryLoadFromBackup() {
                logInfo("从备份恢复成功：\(restoredSession.windows.count) 个窗口")
                return restoredSession
            }

            logError("所有备份恢复尝试均失败，将创建新 session")
            return nil
        }
    }

    /// 尝试从备份加载 Session
    ///
    /// 按顺序尝试每个备份，直到成功或全部失败
    private func tryLoadFromBackup() -> SessionState? {
        for index in 1...maxBackupCount {
            let backupPath = "\(sessionFilePath).bak.\(index)"

            guard FileManager.default.fileExists(atPath: backupPath) else {
                continue
            }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
                let session = try JSONDecoder().decode(SessionState.self, from: data)

                // 验证 session 有效性（至少有一个窗口）
                if session.windows.isEmpty {
                    logWarn("备份 \(index) 为空，跳过")
                    continue
                }

                // 成功恢复，将备份复制回主文件
                logInfo("从备份 \(index) 恢复成功")
                try? FileManager.default.copyItem(atPath: backupPath, toPath: sessionFilePath)

                return session
            } catch {
                logWarn("备份 \(index) 加载失败: \(error)")
                continue
            }
        }

        return nil
    }

    /// 清除 Session
    func clear() {
        do {
            if FileManager.default.fileExists(atPath: sessionFilePath) {
                try FileManager.default.removeItem(atPath: sessionFilePath)
            }
        } catch {
            logError("清除 Session 失败: \(error)")
        }
    }

    // MARK: - Migration (TODO: Remove after v1.1)

    /// 从旧的 UserDefaults 迁移数据
    private func migrateFromUserDefaults() -> SessionState? {
        let userDefaults = UserDefaults.standard
        let sessionKey = "com.eterm.windowSession"

        guard let data = userDefaults.data(forKey: sessionKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let session = try decoder.decode(SessionState.self, from: data)

            // 清除旧数据
            userDefaults.removeObject(forKey: sessionKey)

            return session
        } catch {
            return nil
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
        logWarn("[findScreen] 无法匹配屏幕标识符: \(identifier), fallback 到主屏幕")
        return NSScreen.main ?? NSScreen.screens.first!
    }

    /// 根据标识符和保存的屏幕 frame 查找屏幕
    ///
    /// NSScreenNumber 可能在重启/显示器变化后改变，所以需要额外验证屏幕 frame。
    /// 优先级：
    /// 1. screenId 匹配且 frame 也匹配（完美匹配）
    /// 2. 只有 frame 匹配（screenId 变了，但物理位置没变）
    /// 3. 只有 screenId 匹配（屏幕可能换了位置）
    /// 4. fallback 到主屏幕
    ///
    /// - Parameters:
    ///   - identifier: 屏幕标识符
    ///   - savedFrame: 保存时的屏幕 frame（可选）
    /// - Returns: 找到的 NSScreen
    static func findScreen(withIdentifier identifier: String, savedFrame: CodableRect?) -> NSScreen {
        let screens = NSScreen.screens

        // 如果有保存的 frame，优先按 frame 匹配
        if let savedFrame = savedFrame {
            let savedRect = savedFrame.cgRect

            // 1. 完美匹配：screenId 和 frame 都匹配
            if let screen = screens.first(where: {
                screenIdentifier(for: $0) == identifier && framesMatch($0.frame, savedRect)
            }) {
                logInfo("[findScreen] 完美匹配: \(identifier)")
                return screen
            }

            // 2. Frame 匹配（screenId 可能变了）
            if let screen = screens.first(where: { framesMatch($0.frame, savedRect) }) {
                logInfo("[findScreen] Frame 匹配: 保存的 \(identifier) -> 当前 \(screenIdentifier(for: screen))")
                return screen
            }
        }

        // 3. 只有 screenId 匹配
        if let screen = screens.first(where: { screenIdentifier(for: $0) == identifier }) {
            logWarn("[findScreen] 仅 screenId 匹配，frame 不同: \(identifier)")
            return screen
        }

        // 4. Fallback 到主屏幕
        logWarn("[findScreen] 无法匹配，fallback 到主屏幕")
        return NSScreen.main ?? screens.first!
    }

    /// 检查两个 frame 是否匹配（允许小误差）
    private static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance: CGFloat = 50  // 允许 50pt 误差（处理 Dock/菜单栏等）
        return abs(a.origin.x - b.origin.x) < tolerance &&
               abs(a.origin.y - b.origin.y) < tolerance &&
               abs(a.width - b.width) < tolerance &&
               abs(a.height - b.height) < tolerance
    }
}
