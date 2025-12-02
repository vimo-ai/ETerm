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

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // SwiftData ModelContainer
    private(set) var modelContainer: ModelContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize SwiftData ModelContainer
        do {
            modelContainer = try ModelContainer(
                for: WordEntry.self, GrammarErrorRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
            print("✅ SwiftData ModelContainer initialized successfully")

            // 输出当前数据统计
            printDataStatistics()
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }

        // 启动 Claude Socket Server（接收 Hook 调用）
        ClaudeSocketServer.shared.start()

        // 加载内置插件
        PluginManager.shared.loadBuiltinPlugins()

        // 尝试恢复 Session
        if let session = SessionManager.shared.load(), !session.windows.isEmpty {
            // 恢复每个窗口
            for windowState in session.windows {
                restoreWindow(from: windowState)
            }
        } else {
            // 没有 Session，创建默认窗口
            WindowManager.shared.createWindow()
        }

        // 设置主菜单
        setupMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 停止 Claude Socket Server
        ClaudeSocketServer.shared.stop()

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
            print("\n" + String(repeating: "=", count: 60))
            print("📊 SwiftData 数据统计")
            print(String(repeating: "=", count: 60))

            print("\n📚 单词本:")
            print("  总单词数: \(wordCount)")
            print("  高频单词 (Hit ≥ 2): \(frequentWords.count)")

            if !frequentWords.isEmpty {
                print("  TOP 5 高频单词:")
                for (index, word) in frequentWords.prefix(5).enumerated() {
                    let lastQuery = word.lastQueryDate?.formatted(date: .omitted, time: .shortened) ?? "未知"
                    print("    \(index + 1). \(word.word) - \(word.hitCount)次 (最近: \(lastQuery))")
                }
            }

            print("\n📝 语法档案:")
            print("  总错误数: \(errorCount)")

            if !categoryStats.isEmpty {
                print("  错误分类统计:")
                for (category, count) in categoryStats.prefix(5) {
                    let displayName = categoryDisplayName(category)
                    print("    • \(displayName): \(count)次")
                }
            }

            print("\n" + String(repeating: "=", count: 60) + "\n")

        } catch {
            print("❌ 读取数据统计失败: \(error)")
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

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Session 恢复

    /// 从窗口状态恢复窗口
    ///
    /// - Parameter windowState: 窗口状态
    private func restoreWindow(from windowState: WindowState) {
        let frame = windowState.frame.cgRect

        // 使用保存的位置、尺寸和屏幕信息创建窗口
        // TODO: 未来可以扩展恢复完整的 Page/Panel/Tab 布局
        WindowManager.shared.createWindow(
            inheritCwd: nil,
            frame: frame,
            screenIdentifier: windowState.screenIdentifier
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
}
