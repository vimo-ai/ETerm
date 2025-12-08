//
//  CoreCommandsBootstrap.swift
//  ETerm
//
//  核心命令注册器
//
//  在应用启动时注册所有核心功能的命令和快捷键

import Foundation
import AppKit

/// 核心命令启动器
///
/// 负责在应用启动时将所有核心功能注册为命令，并绑定默认快捷键
/// 这样核心功能和插件功能使用相同的命令系统
final class CoreCommandsBootstrap {

    /// 确保只注册一次
    private static var isRegistered = false

    /// 清理剪贴板临时目录中的所有文件
    /// 应在应用启动时调用
    static func cleanupClipboardTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETerm")
            .appendingPathComponent("clipboard")

        do {
            let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            // 目录不存在或为空，忽略
        }
    }

    /// 注册所有核心命令和快捷键
    static func registerCoreCommands() {
        guard !isRegistered else {
            print("⚠️ [CoreCommands] 核心命令已经注册过了，跳过")
            return
        }
        isRegistered = true

        let commands = CommandRegistry.shared
        let keyboard = KeyboardServiceImpl.shared

        // ─────────────────────────────────────────
        // Page 管理（Window 级别）
        // ─────────────────────────────────────────

        // 切换到指定 Page
        for i in 0..<9 {
            commands.register(Command(
                id: "page.switchTo.\(i)",
                title: "切换到 Page \(i + 1)",
                icon: "square.stack.3d.up"
            ) { context in
                context.coordinator?.switchToPage(i)
            })
            keyboard.bind(.ctrl("\(i + 1)"), to: "page.switchTo.\(i)", when: nil)
        }

        // 上一个/下一个 Page
        commands.register(Command(
            id: "page.previous",
            title: "上一个 Page",
            icon: "chevron.left.square"
        ) { context in
            context.coordinator?.switchToPreviousPage()
        })
        keyboard.bind(.ctrl("["), to: "page.previous", when: nil)

        commands.register(Command(
            id: "page.next",
            title: "下一个 Page",
            icon: "chevron.right.square"
        ) { context in
            context.coordinator?.switchToNextPage()
        })
        keyboard.bind(.ctrl("]"), to: "page.next", when: nil)

        // 新建/关闭 Page
        commands.register(Command(
            id: "page.create",
            title: "新建 Page",
            icon: "plus.square"
        ) { context in
            context.coordinator?.createPage()
        })
        keyboard.bind(.ctrl("t"), to: "page.create", when: nil)

        commands.register(Command(
            id: "page.close",
            title: "关闭当前 Page",
            icon: "xmark.square"
        ) { context in
            context.coordinator?.closeCurrentPage()
        })
        keyboard.bind(.ctrl("w"), to: "page.close", when: nil)

        // ─────────────────────────────────────────
        // Tab 管理（Panel 级别）
        // ─────────────────────────────────────────

        // 切换到指定 Tab
        for i in 0..<9 {
            commands.register(Command(
                id: "tab.switchTo.\(i)",
                title: "切换到 Tab \(i + 1)",
                icon: "rectangle.stack"
            ) { context in
                context.coordinator?.switchToTab(i)
            })
            keyboard.bind(.cmd("\(i + 1)"), to: "tab.switchTo.\(i)", when: nil)
        }

        // 上一个/下一个 Tab
        commands.register(Command(
            id: "tab.previous",
            title: "上一个 Tab",
            icon: "chevron.left"
        ) { context in
            context.coordinator?.previousTab()
        })
        keyboard.bind(.cmd("["), to: "tab.previous", when: nil)

        commands.register(Command(
            id: "tab.next",
            title: "下一个 Tab",
            icon: "chevron.right"
        ) { context in
            context.coordinator?.nextTab()
        })
        keyboard.bind(.cmd("]"), to: "tab.next", when: nil)

        // 新建 Tab
        commands.register(Command(
            id: "tab.create",
            title: "新建 Tab",
            icon: "plus.rectangle"
        ) { context in
            context.coordinator?.createTab()
        })
        keyboard.bind(.cmd("t"), to: "tab.create", when: nil)

        // 智能关闭（Cmd+W）
        commands.register(Command(
            id: "tab.smartClose",
            title: "关闭",
            icon: "xmark"
        ) { context in
            guard let coordinator = context.coordinator else { return }

            // 检查当前终端是否有正在运行的进程
            if coordinator.hasActiveTerminalRunningProcess() {
                DispatchQueue.main.async {
                    let processName = coordinator.getActiveTerminalForegroundProcessName() ?? "进程"
                    Self.showCloseTabWithProcessConfirmation(processName: processName) {
                        // 用户确认关闭，执行关闭逻辑
                        let result = coordinator.handleSmartClose()
                        if case .shouldCloseWindow = result {
                            let isLastWindow = WindowManager.shared.windowCount <= 1
                            Self.showCloseWindowConfirmation(isLastWindow: isLastWindow)
                        }
                    }
                }
                return
            }

            // 没有运行的进程，直接关闭
            let result = coordinator.handleSmartClose()

            if case .shouldCloseWindow = result {
                // 需要关闭窗口，弹出确认对话框
                DispatchQueue.main.async {
                    let isLastWindow = WindowManager.shared.windowCount <= 1
                    Self.showCloseWindowConfirmation(isLastWindow: isLastWindow)
                }
            }
        })
        keyboard.bind(.cmd("w"), to: "tab.smartClose", when: nil)

        // 分屏
        commands.register(Command(
            id: "panel.splitHorizontal",
            title: "水平分屏",
            icon: "rectangle.split.2x1"
        ) { context in
            context.coordinator?.splitHorizontal()
        })
        keyboard.bind(.cmd("d"), to: "panel.splitHorizontal", when: nil)

        commands.register(Command(
            id: "panel.splitVertical",
            title: "垂直分屏",
            icon: "rectangle.split.1x2"
        ) { context in
            context.coordinator?.splitVertical()
        })
        keyboard.bind(.cmdShift("d"), to: "panel.splitVertical", when: nil)

        // ─────────────────────────────────────────
        // 编辑操作
        // ─────────────────────────────────────────

        // 复制（有选中时）
        commands.register(Command(
            id: "edit.copy",
            title: "复制",
            icon: "doc.on.doc"
        ) { context in
            context.coordinator?.copySelection()
        })
        keyboard.bind(.cmd("c"), to: "edit.copy", when: "hasSelection")

        // 中断（无选中时，Cmd+C 发送 Ctrl+C）
        commands.register(Command(
            id: "terminal.interrupt",
            title: "中断命令",
            icon: "stop.circle"
        ) { context in
            context.coordinator?.sendCtrlC()
        })
        keyboard.bind(.cmd("c"), to: "terminal.interrupt", when: "!hasSelection")

        // 粘贴
        commands.register(Command(
            id: "edit.paste",
            title: "粘贴",
            icon: "doc.on.clipboard"
        ) { context in
            context.coordinator?.pasteFromClipboard()
        })
        keyboard.bind(.cmd("v"), to: "edit.paste", when: nil)

        // 全选
        commands.register(Command(
            id: "edit.selectAll",
            title: "全选",
            icon: "selection.pin.in.out"
        ) { context in
            context.coordinator?.selectAll()
        })
        keyboard.bind(.cmd("a"), to: "edit.selectAll", when: nil)

        // 清除选中（仅在 selection 模式）
        commands.register(Command(
            id: "selection.clear",
            title: "清除选中",
            icon: "xmark.circle"
        ) { context in
            context.coordinator?.clearSelection()
        })
        keyboard.bind(.escape, to: "selection.clear", when: "mode == selection")

        // ─────────────────────────────────────────
        // 字体大小
        // ─────────────────────────────────────────

        commands.register(Command(
            id: "font.increase",
            title: "放大字体",
            icon: "textformat.size.larger"
        ) { context in
            context.coordinator?.changeFontSize(operation: .increase)
        })
        keyboard.bind(.cmd("="), to: "font.increase", when: nil)
        keyboard.bind(.cmd("+"), to: "font.increase", when: nil)  // Shift+= 产生 +

        commands.register(Command(
            id: "font.decrease",
            title: "缩小字体",
            icon: "textformat.size.smaller"
        ) { context in
            context.coordinator?.changeFontSize(operation: .decrease)
        })
        keyboard.bind(.cmd("-"), to: "font.decrease", when: nil)

        commands.register(Command(
            id: "font.reset",
            title: "重置字体大小",
            icon: "textformat.size"
        ) { context in
            context.coordinator?.resetFontSize()
        })
        keyboard.bind(.cmd("0"), to: "font.reset", when: nil)

        // ─────────────────────────────────────────
        // 辅助功能
        // ─────────────────────────────────────────

        commands.register(Command(
            id: "translation.toggle",
            title: "切换翻译模式",
            icon: "text.bubble"
        ) { context in
            TranslationModeStore.shared.toggle()
        })
        keyboard.bind(.cmdShift("y"), to: "translation.toggle", when: nil)

        commands.register(Command(
            id: "sidebar.toggle",
            title: "打开侧边栏",
            icon: "sidebar.left"
        ) { context in
            NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
        })
        keyboard.bind(.cmd(","), to: "sidebar.toggle", when: nil)

        // 终端搜索
        commands.register(Command(
            id: "terminal.search",
            title: "搜索",
            icon: "magnifyingglass"
        ) { context in
            context.coordinator?.toggleTerminalSearch()
        })
        keyboard.bind(.cmd("f"), to: "terminal.search", when: nil)

        print("✅ [CoreCommands] 已注册所有核心命令和快捷键")
    }

    // MARK: - 关闭确认

    /// 显示关闭 Tab 时有运行进程的确认对话框
    private static func showCloseTabWithProcessConfirmation(processName: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "终端正在运行 \(processName)"
        alert.informativeText = "关闭此终端将终止正在运行的进程，确定要继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    /// 显示关闭窗口确认对话框
    private static func showCloseWindowConfirmation(isLastWindow: Bool) {
        let alert = NSAlert()

        if isLastWindow {
            alert.messageText = "确定要退出 ETerm 吗？"
            alert.informativeText = "这是最后一个窗口，关闭后将退出应用程序。"
            alert.addButton(withTitle: "退出")
        } else {
            alert.messageText = "确定要关闭此窗口吗？"
            alert.informativeText = "窗口中的所有终端会话将被关闭。"
            alert.addButton(withTitle: "关闭")
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if isLastWindow {
                NSApplication.shared.terminate(nil)
            } else {
                NSApplication.shared.keyWindow?.close()
            }
        }
    }
}

// MARK: - TerminalWindowCoordinator 扩展

extension TerminalWindowCoordinator {
    /// 切换到指定索引的 Page
    func switchToPage(_ index: Int) {
        let pages = allPages
        guard index < pages.count else { return }
        let targetPageId = pages[index].pageId
        switchToPage(targetPageId)
    }

    /// 切换到指定索引的 Tab
    func switchToTab(_ index: Int) {
        guard let panelId = activePanelId,
              let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        let tabs = panel.tabs
        guard index < tabs.count else { return }
        let targetTabId = tabs[index].tabId
        handleTabClick(panelId: panelId, tabId: targetTabId)
    }

    /// 上一个 Tab
    func previousTab() {
        guard let panelId = activePanelId,
              let panel = terminalWindow.getPanel(panelId),
              let currentIndex = panel.tabs.firstIndex(where: { $0.tabId == panel.activeTabId }) else {
            return
        }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : panel.tabs.count - 1
        let targetTabId = panel.tabs[newIndex].tabId
        handleTabClick(panelId: panelId, tabId: targetTabId)
    }

    /// 下一个 Tab
    func nextTab() {
        guard let panelId = activePanelId,
              let panel = terminalWindow.getPanel(panelId),
              let currentIndex = panel.tabs.firstIndex(where: { $0.tabId == panel.activeTabId }) else {
            return
        }

        let newIndex = (currentIndex + 1) % panel.tabs.count
        let targetTabId = panel.tabs[newIndex].tabId
        handleTabClick(panelId: panelId, tabId: targetTabId)
    }

    /// 创建新 Tab（在当前 Panel）
    func createTab() {
        guard let panelId = activePanelId else { return }
        handleAddTab(panelId: panelId)
    }

    /// 水平分屏
    func splitHorizontal() {
        guard let panelId = activePanelId else { return }
        handleSplitPanel(panelId: panelId, direction: .horizontal)
    }

    /// 垂直分屏
    func splitVertical() {
        guard let panelId = activePanelId else { return }
        handleSplitPanel(panelId: panelId, direction: .vertical)
    }

    /// 复制选中内容
    func copySelection() {
        // 获取当前激活的终端
        guard let terminalId = getActiveTerminalId() else { return }

        // 直接从 Rust 获取选中的文本
        if let text = getSelectionText(terminalId: terminalId) {
            // 复制到剪贴板
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// 发送 Ctrl+C（中断）
    func sendCtrlC() {
        guard let terminalId = getActiveTerminalId() else { return }
        writeInput(terminalId: terminalId, data: "\u{03}")  // Ctrl+C = 0x03
    }

    /// 从剪贴板粘贴
    func pasteFromClipboard() {
        guard let terminalId = getActiveTerminalId() else { return }

        let pasteboard = NSPasteboard.general

        // 优先检查图片 (支持 PNG、TIFF 等)
        // Claude CLI 期望的是文件路径，不是 iTerm2 协议
        if let imageData = getImageDataFromPasteboard(pasteboard) {
            if let filePath = saveImageToTempFile(imageData) {
                writeInput(terminalId: terminalId, data: filePath)
            }
            return
        }

        // 检查文本
        if let text = pasteboard.string(forType: .string) {
            writeInput(terminalId: terminalId, data: text)
        }
    }

    /// ETerm 剪贴板图片临时目录
    private var clipboardTempDirectory: URL {
        Self.getClipboardTempDirectory()
    }

    /// 获取剪贴板图片临时目录（静态）
    private static func getClipboardTempDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETerm")
            .appendingPathComponent("clipboard")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// 保存图片到临时文件，返回文件路径
    private func saveImageToTempFile(_ imageData: Data) -> String? {
        let fileName = "clipboard_\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let fileURL = clipboardTempDirectory.appendingPathComponent(fileName)

        do {
            try imageData.write(to: fileURL)
            return fileURL.path
        } catch {
            return nil
        }
    }

    /// 从剪贴板获取图片数据 (PNG 格式)
    private func getImageDataFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        // 尝试读取 PNG
        if let data = pasteboard.data(forType: .png) {
            return data
        }

        // 尝试读取 TIFF 并转换为 PNG
        if let data = pasteboard.data(forType: .tiff),
           let image = NSImage(data: data),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }

        return nil
    }


    /// 全选
    func selectAll() {
        // TODO: 实现全选功能
        // 需要获取终端的所有内容范围并设置选区
        print("⚠️ [CoreCommands] selectAll 功能待实现")
    }

    /// 清除选中
    func clearSelection() {
        guard let terminalId = getActiveTerminalId() else { return }
        _ = clearSelection(terminalId: terminalId)
    }

    /// 重置字体大小
    func resetFontSize() {
        changeFontSize(operation: .reset)
    }
}
