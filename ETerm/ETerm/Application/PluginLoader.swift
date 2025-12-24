import Foundation
import SwiftUI

/// 插件加载器 - 负责扫描和加载 PlugIns 目录下的所有 Bundle 插件
final class PluginLoader {
    static let shared = PluginLoader()

    private var loadedPlugins: [String: Bundle] = [:]

    private init() {
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        // 监听 Bundle 插件的侧边栏注册请求
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.RegisterSidebarTab"),
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let pluginId = userInfo["pluginId"] as? String,
                  let pluginName = userInfo["pluginName"] as? String,
                  let tabId = userInfo["tabId"] as? String,
                  let title = userInfo["title"] as? String,
                  let icon = userInfo["icon"] as? String,
                  let viewProvider = userInfo["viewProvider"] as? () -> AnyView else {
                return
            }

            let tab = SidebarTab(id: tabId, title: title, icon: icon, viewProvider: viewProvider)
            SidebarRegistry.shared.registerTab(for: pluginId, pluginName: pluginName, tab: tab)
        }
    }

    /// 扫描并加载所有插件
    func loadAllPlugins() {
        // 加载插件（统一从 ~/.eterm/plugins/ 加载）
        let pluginsPath = ETermPaths.plugins
        let pluginsURL = URL(fileURLWithPath: pluginsPath)

        // 确保插件目录存在
        try? FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)

        loadPluginsFrom(directory: pluginsURL, type: "plugin")
    }

    /// 从指定目录加载插件
    /// 新结构：plugins/{PluginName}/{PluginName}.bundle
    private func loadPluginsFrom(directory: URL, type: String) {
        do {
            // 扫描每个插件目录
            let pluginDirs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            var bundles: [URL] = []

            // 在每个插件目录中查找 .bundle
            for pluginDir in pluginDirs {
                let pluginBundles = try FileManager.default.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "bundle" }

                bundles.append(contentsOf: pluginBundles)
            }

            bundles.forEach { loadPlugin(at: $0) }

        } catch {
            // Scanning error, silently ignore
        }
    }

    /// 加载单个插件
    @discardableResult
    func loadPlugin(at url: URL) -> Bool {
        let pluginName = url.deletingPathExtension().lastPathComponent

        guard let bundle = Bundle(url: url) else {
            return false
        }

        // 加载 bundle（这会自动加载 bundle 里的 Contents/MacOS/ 下的主 dylib）
        guard bundle.load() else {
            return false
        }

        let identifier = bundle.bundleIdentifier ?? pluginName
        loadedPlugins[identifier] = bundle

        // 调用插件入口点（如果定义了 principalClass）
        activatePlugin(bundle, name: pluginName)

        return true
    }

    /// 激活插件
    private func activatePlugin(_ bundle: Bundle, name: String) {
        // 如果 Info.plist 中定义了 NSPrincipalClass，自动实例化
        if let principalClass = bundle.principalClass as? NSObject.Type {
            let instance = principalClass.init()

            // 尝试调用 activate 方法（如果存在）
            if instance.responds(to: NSSelectorFromString("activate")) {
                instance.perform(NSSelectorFromString("activate"))
            }
        }
    }

    /// 卸载插件
    func unloadPlugin(identifier: String) {
        guard let bundle = loadedPlugins[identifier] else {
            return
        }

        // 尝试调用 deactivate（如果是 principalClass）
        if let principalClass = bundle.principalClass as? NSObject.Type {
            // 注意：无法直接获取之前的实例，需要插件自己管理单例
        }

        bundle.unload()
        loadedPlugins.removeValue(forKey: identifier)
    }

    /// 重新加载所有插件
    func reloadAllPlugins() {
        // 卸载所有已加载的插件
        loadedPlugins.keys.forEach { unloadPlugin(identifier: $0) }

        // 重新加载
        loadAllPlugins()
    }

    /// 获取所有已加载的 Bundle 插件信息（给 UI 用）
    func allPluginInfos() -> [PluginInfo] {
        loadedPlugins.map { (identifier, bundle) in
            let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? identifier
            let version = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1.0.0"

            return PluginInfo(
                id: identifier,
                name: name,
                version: version,
                dependencies: [],
                isLoaded: true,
                isEnabled: true,
                dependents: []
            )
        }.sorted { $0.name < $1.name }
    }
}
