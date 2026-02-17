//
//  FilePreviewKitPlugin.swift
//  FilePreviewKit
//
//  文件预览插件 - 提供文件浏览器和 Quick Look 预览功能

import Foundation
import SwiftUI
import ETermKit

// MARK: - FileBrowserService (全局单例)

/// 文件浏览器服务单例，供侧边栏和右键菜单调用
@MainActor
final class FileBrowserService {
    static let shared = FileBrowserService()

    var host: HostBridge?

    private init() {}

    func openFileBrowser(rootPath: String? = nil) {
        logInfo("[FilePreviewKit] openFileBrowser called, host=\(host != nil ? "set" : "nil")")
        guard let host = host else {
            logWarn("[FilePreviewKit] host is nil, cannot open file browser")
            return
        }
        let cwd = rootPath ?? host.getActiveTabCwd() ?? NSHomeDirectory()
        logInfo("[FilePreviewKit] creating plugin page with cwd=\(cwd)")
        guard let pageHost = host as? PluginPageHostBridge else {
            logWarn("[FilePreviewKit] host does not support PluginPageHostBridge")
            return
        }
        pageHost.createPluginPage(title: "📁 文件") {
            AnyView(FileBrowserView(rootPath: cwd))
        }
    }

    /// 打开文件预览（作为 Tab 添加到当前 Panel）
    func openPreview(url: URL) {
        guard let host = host else {
            logWarn("[FilePreviewKit] host is nil, cannot open preview")
            return
        }
        let fileName = url.lastPathComponent
        logInfo("[FilePreviewKit] opening preview for \(fileName)")
        guard let tabHost = host as? ViewTabHostBridge else {
            logWarn("[FilePreviewKit] host does not support ViewTabHostBridge")
            return
        }
        tabHost.createViewTab(title: fileName, placement: .tab) {
            AnyView(FilePreviewView(fileURL: url))
        }
    }
}

// MARK: - Plugin Entry

@objc(FilePreviewKitPlugin)
@MainActor
public final class FilePreviewKitPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.file-preview"

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        logInfo("[FilePreviewKit] activate called")
        FileBrowserService.shared.host = host

        // 注册 openFileBrowser 服务（供右键菜单等外部调用）
        host.registerService(name: "openFileBrowser") { params in
            let cwd = params["cwd"] as? String ?? NSHomeDirectory()
            Task { @MainActor in
                FileBrowserService.shared.openFileBrowser(rootPath: cwd)
            }
            return ["status": "ok"]
        }
    }

    public func deactivate() {
        FileBrowserService.shared.host = nil
    }

    // MARK: - Sidebar

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "file-browser":
            let cwd = FileBrowserService.shared.host?.getActiveTabCwd() ?? NSHomeDirectory()
            return AnyView(FileBrowserView(rootPath: cwd))
        default:
            return nil
        }
    }
}
