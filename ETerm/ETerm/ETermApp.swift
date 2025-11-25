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

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建主窗口
        WindowManager.shared.createWindow()

        // 设置主菜单
        setupMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理工作
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭时退出应用
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
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

    // MARK: - 菜单操作

    @objc private func newWindow(_ sender: Any?) {
        WindowManager.shared.createWindow()
    }
}
