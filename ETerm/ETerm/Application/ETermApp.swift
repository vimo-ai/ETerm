//
//  ETermApp.swift
//  ETerm
//
//  AppDelegate - 应用生命周期管理
//
//  Created by 💻higuaifan on 2025/11/15.
//

import AppKit
import SwiftUI
import SwiftData
import ETermKit

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // SwiftData ModelContainer
    private(set) var modelContainer: ModelContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建 ETerm 数据目录
        do {
            try ETermPaths.createDirectories()
        } catch {
            logError("创建 ETerm 数据目录失败: \(error)")
        }

        // 设置 Rust 日志桥接（让 Rust 端日志能够被持久化）
        setupRustLogBridge()

        // Initialize SwiftData ModelContainer
        do {
            // 尝试使用自定义路径
            let wordsDBURL = URL(fileURLWithPath: ETermPaths.wordsDatabase)
            let config = ModelConfiguration(url: wordsDBURL)

            modelContainer = try ModelContainer(
                for: WordEntry.self, GrammarErrorRecord.self,
                configurations: config
            )

            // 输出当前数据统计
            printDataStatistics()
        } catch {
            // 如果自定义路径失败，回退到默认路径
            logWarn("使用自定义路径初始化 SwiftData 失败，回退到默认路径: \(error)")

            do {
                modelContainer = try ModelContainer(
                    for: WordEntry.self, GrammarErrorRecord.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: false)
                )
            } catch {
                fatalError("Failed to initialize ModelContainer: \(error)")
            }
        }

        // 启动 AI Socket Server（为 Shell 提供 AI 补全服务）
        startAISocketServer()

        // 启动 MCP Server（HTTP 模式，端口 11218）
        MCPServerCoordinator.shared.start()

        // 启动事件网关（供外部进程订阅事件）
        EventGateway.shared.start()

        // 初始化翻译模式状态（注册通知监听）
        _ = TranslationModeStore.shared

        // 注册核心命令（必须在加载插件之前，让插件可以覆盖）
        CoreCommandsBootstrap.registerCoreCommands()

        // 清理上次运行残留的剪贴板临时文件
        CoreCommandsBootstrap.cleanupClipboardTempFiles()

        // 启动会话录制器
        SessionRecorder.shared.setupIntegration()

        // 扫描并解析插件 manifest
        SDKPluginLoader.shared.scanAndParseManifests()

        // 同步加载 immediate 插件（用 RunLoop 等待，允许 @MainActor 回调）
        var immediateLoaded = false
        Task {
            await SDKPluginLoader.shared.loadImmediatePlugins()
            immediateLoaded = true
        }
        while !immediateLoaded {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        // 设置事件桥接（immediate 插件加载后立即设置，以便拦截窗口创建事件）
        SDKEventBridge.shared.setup()

        // 读取 Session
        let session = SessionManager.shared.load()

        // DEBUG: 屏幕恢复调试
        logInfo("[ScreenDebug] NSScreen.screens.count: \(NSScreen.screens.count)")
        for (i, screen) in NSScreen.screens.enumerated() {
            let screenId = SessionManager.screenIdentifier(for: screen)
            logInfo("[ScreenDebug] Screen[\(i)]: id=\(screenId) frame=\(screen.frame)")
        }
        logInfo("[ScreenDebug] NSScreen.main: \(NSScreen.main.map { SessionManager.screenIdentifier(for: $0) } ?? "nil")")
        if let session = session {
            for (i, ws) in session.windows.enumerated() {
                logInfo("[ScreenDebug] SavedWindow[\(i)]: screenId=\(ws.screenIdentifier ?? "nil") frame=\(ws.frame.cgRect)")
            }
        }

        // 创建/恢复窗口
        if let session = session, !session.windows.isEmpty {
            for windowState in session.windows {
                restoreWindow(from: windowState)
            }
        } else {
            WindowManager.shared.createWindow()
        }

        // 恢复 immediate 插件的 View Tab（窗口已恢复，ViewTabRegistry 可能还有空缺）
        SDKPluginLoader.shared.restoreAllPendingViewTabs()

        // 检测并显示首次启动引导
        if OnboardingManager.shared.shouldShowOnboarding() {
            // 延迟一点显示，让主窗口先完成渲染
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingManager.shared.showOnboarding()
            }
        }

        // 后台加载 background 插件
        Task.detached(priority: .userInitiated) {
            await SDKPluginLoader.shared.loadBackgroundPlugins()

            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.PluginsLoaded"),
                    object: nil
                )
            }
        }

        // 设置主菜单
        setupMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 停用所有 SDK 插件（确保子进程被清理）
        SDKPluginLoader.shared.deactivateAll()

        // 停止 Extension Host
        Task {
            await ExtensionHostManager.shared.stop()
        }

        // 停止 AI Socket Server
        AISocketServer.shared.stop()

        // 停止 MCP Server
        MCPServerCoordinator.shared.stop()

        // 停止事件网关
        EventGateway.shared.stop()

        // 停止会话录制并导出（用于调试）
        SessionRecorder.shared.stopRecording()

        // 保存 Session
        let windowStates = WindowManager.shared.captureAllWindowStates()
        SessionManager.shared.save(windows: windowStates)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭时退出应用
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - 数据统计

    private func printDataStatistics() {
        let context = modelContainer.mainContext

        do {
            // 统计单词本
            let wordCount = try context.fetchCount(FetchDescriptor<WordEntry>())

            // 统计高频单词 (Hit >= 2)
            let frequentDescriptor = FetchDescriptor<WordEntry>(
                predicate: #Predicate { $0.hitCount >= 2 },
                sortBy: [SortDescriptor(\.hitCount, order: .reverse)]
            )
            let frequentWords = try context.fetch(frequentDescriptor)

            // 统计语法错误
            let errorCount = try context.fetchCount(FetchDescriptor<GrammarErrorRecord>())

            // 按分类统计语法错误
            let allErrors = try context.fetch(FetchDescriptor<GrammarErrorRecord>())
            let categoryStats = Dictionary(grouping: allErrors, by: { $0.category })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }

            // 输出统计信息


            if !frequentWords.isEmpty {
                for (index, word) in frequentWords.prefix(5).enumerated() {
                    let lastQuery = word.lastQueryDate?.formatted(date: .omitted, time: .shortened) ?? "未知"
                }
            }


            if !categoryStats.isEmpty {
                for (category, count) in categoryStats.prefix(5) {
                    let displayName = categoryDisplayName(category)
                }
            }


        } catch {
        }
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "tense": return "时态"
        case "article": return "冠词"
        case "preposition": return "介词"
        case "subject_verb_agreement": return "主谓一致"
        case "word_order": return "词序"
        case "singular_plural": return "单复数"
        case "punctuation": return "标点"
        case "spelling": return "拼写"
        case "word_choice": return "用词"
        case "sentence_structure": return "句子结构"
        case "other": return "其他"
        default: return category
        }
    }

    // MARK: - 菜单设置

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(title: "关于 ETerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 ETerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))

        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 ETerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        mainMenu.addItem(appMenuItem)

        // 文件菜单
        let fileMenu = NSMenu(title: "文件")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu

        // Cmd+Shift+N: 新建窗口
        let newWindowItem = NSMenuItem(title: "新建窗口", action: #selector(newWindow(_:)), keyEquivalent: "N")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newWindowItem)

        fileMenu.addItem(NSMenuItem.separator())

        // Cmd+Shift+O: 一行命令（禁用菜单项，由插件系统处理）
        let oneLineCommandItem = NSMenuItem(title: "一行命令", action: nil, keyEquivalent: "O")
        oneLineCommandItem.keyEquivalentModifierMask = [.command, .shift]
        oneLineCommandItem.isEnabled = false  // 禁用菜单项，让插件系统处理
        fileMenu.addItem(oneLineCommandItem)

        fileMenu.addItem(NSMenuItem.separator())

        // 关闭 Tab/Page 由 KeyboardSystem 处理，菜单只显示提示
        let closeTabItem = NSMenuItem(title: "关闭 Tab", action: nil, keyEquivalent: "")
        closeTabItem.keyEquivalent = "w"
        closeTabItem.keyEquivalentModifierMask = [.command]
        closeTabItem.isEnabled = false  // 禁用菜单项，让键盘系统处理
        fileMenu.addItem(closeTabItem)

        let closePageItem = NSMenuItem(title: "关闭 Page", action: nil, keyEquivalent: "")
        closePageItem.keyEquivalent = "W"
        closePageItem.keyEquivalentModifierMask = [.command, .shift]
        closePageItem.isEnabled = false  // 禁用菜单项，让键盘系统处理
        fileMenu.addItem(closePageItem)

        mainMenu.addItem(fileMenuItem)

        // 编辑菜单
        let editMenu = NSMenu(title: "编辑")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        mainMenu.addItem(editMenuItem)

        // 窗口菜单
        let windowMenu = NSMenu(title: "窗口")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        mainMenu.addItem(windowMenuItem)

        // 调试菜单
        let debugMenu = NSMenu(title: "调试")
        let debugMenuItem = NSMenuItem()
        debugMenuItem.submenu = debugMenu

        // 添加调试菜单项
        for item in DebugSessionExporter.shared.createDebugMenuItems() {
            debugMenu.addItem(item)
        }

        mainMenu.addItem(debugMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Session 恢复

    /// 从窗口状态恢复窗口
    ///
    /// - Parameter windowState: 窗口状态
    private func restoreWindow(from windowState: WindowState) {
        let frame = windowState.frame.cgRect

        // 创建窗口（传入完整的 WindowState 用于恢复）
        WindowManager.shared.createWindowWithState(
            windowState: windowState,
            frame: frame
        )
    }

    // MARK: - 菜单操作

    @objc private func newWindow(_ sender: Any?) {
        // 获取当前 focus 窗口的 CWD
        var inheritedCwd: String? = nil

        if let keyWindow = WindowManager.shared.keyWindow,
           let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber),
           let activePanelId = coordinator.activePanelId,
           let panel = coordinator.terminalWindow.getPanel(activePanelId),
           let activeTab = panel.tabs.first(where: { $0.tabId == panel.activeTabId }),
           let terminalId = activeTab.rustTerminalId {
            // 获取当前激活终端的 CWD
            inheritedCwd = coordinator.getCwd(terminalId: Int(terminalId))
        }

        // 创建新窗口，继承 CWD
        WindowManager.shared.createWindow(inheritCwd: inheritedCwd)
    }

    // MARK: - AI Socket Server

    private func startAISocketServer() {
        // 设置请求处理器
        AISocketServer.shared.handler = AICompletionService.shared

        // 启动服务器
        do {
            try AISocketServer.shared.start()
        } catch {
            logError("启动 AI Socket Server 失败: \(error)")
        }

        // 初始化 Ollama 服务（后台检查健康状态）
        Task {
            let healthy = await OllamaService.shared.checkHealth()
            if healthy {
                await OllamaService.shared.warmUp()
            }
        }
    }
}
