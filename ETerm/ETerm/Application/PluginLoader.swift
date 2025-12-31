import Foundation
import SwiftUI

/// 插件加载器 - 负责扫描和加载 PlugIns 目录下的所有 Bundle 插件
final class PluginLoader {
    static let shared = PluginLoader()

    private var loadedPlugins: [String: Bundle] = [:]

    /// 所有扫描到的插件 URL（包括禁用的）
    private var scannedPlugins: [String: URL] = [:]

    /// 禁用的插件 ID 集合（持久化）
    private var disabledPluginIds: Set<String> {
        get { loadDisabledPlugins() }
        set { saveDisabledPlugins(newValue) }
    }

    /// 配置文件路径
    private let configFilePath = ETermPaths.bundlePluginsConfig

    private init() {
        setupNotificationObservers()
    }

    // MARK: - 持久化

    private struct BundlePluginsConfig: Codable {
        var disabledPlugins: [String]
    }

    private func loadDisabledPlugins() -> Set<String> {
        guard FileManager.default.fileExists(atPath: configFilePath) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configFilePath))
            let config = try JSONDecoder().decode(BundlePluginsConfig.self, from: data)
            return Set(config.disabledPlugins)
        } catch {
            return []
        }
    }

    private func saveDisabledPlugins(_ disabledPlugins: Set<String>) {
        do {
            try ETermPaths.ensureParentDirectory(for: configFilePath)

            let config = BundlePluginsConfig(disabledPlugins: Array(disabledPlugins).sorted())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            // Ignore save errors
        }
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
        // 加载插件（统一从 ~/.vimo/eterm/plugins/ 加载）
        let pluginsPath = ETermPaths.plugins
        let pluginsURL = URL(fileURLWithPath: pluginsPath)

        // 确保插件目录存在
        try? FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)

        scanAndLoadPlugins(from: pluginsURL)
    }

    /// 扫描并加载插件
    /// 新结构：plugins/{PluginName}/{PluginName}.bundle
    private func scanAndLoadPlugins(from directory: URL) {
        do {
            // 扫描每个插件目录
            let pluginDirs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            var bundles: [URL] = []

            // 在每个插件目录中查找 .bundle（排除 SDK 插件，它们有 manifest.json）
            for pluginDir in pluginDirs {
                let pluginBundles = try FileManager.default.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil
                ).filter { url in
                    guard url.pathExtension == "bundle" else { return false }
                    // 检查是否有 manifest.json（SDK 插件标志）
                    let manifestPath = url.appendingPathComponent("Contents/Resources/manifest.json")
                    return !FileManager.default.fileExists(atPath: manifestPath.path)
                }

                bundles.append(contentsOf: pluginBundles)
            }

            // 保存扫描结果并加载
            for bundleURL in bundles {
                let identifier = bundleURL.deletingPathExtension().lastPathComponent
                scannedPlugins[identifier] = bundleURL

                // 只加载未禁用的插件
                if !disabledPluginIds.contains(identifier) {
                    loadPlugin(at: bundleURL)
                }
            }

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

    /// 获取所有 Bundle 插件信息（包括已禁用的）
    func allPluginInfos() -> [PluginInfo] {
        scannedPlugins.map { (identifier, url) in
            let bundle = loadedPlugins[identifier]
            let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle?.infoDictionary?["CFBundleName"] as? String
                ?? identifier
            let version = bundle?.infoDictionary?["CFBundleVersion"] as? String ?? "1.0.0"
            let isEnabled = !disabledPluginIds.contains(identifier)
            let isLoaded = loadedPlugins[identifier] != nil

            return PluginInfo(
                id: identifier,
                name: name,
                version: version,
                dependencies: [],
                isLoaded: isLoaded,
                isEnabled: isEnabled,
                dependents: []
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: - 热插拔 API

    /// 检查插件是否启用
    func isPluginEnabled(_ pluginId: String) -> Bool {
        !disabledPluginIds.contains(pluginId)
    }

    /// 检查插件是否已加载
    func isPluginLoaded(_ pluginId: String) -> Bool {
        loadedPlugins[pluginId] != nil
    }

    /// 启用插件（热加载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @discardableResult
    func enablePlugin(_ pluginId: String) -> Bool {
        guard let url = scannedPlugins[pluginId] else {
            return false
        }

        // 从禁用列表移除
        var disabled = disabledPluginIds
        disabled.remove(pluginId)
        disabledPluginIds = disabled

        // 加载插件
        return loadPlugin(at: url)
    }

    /// 禁用插件（热卸载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @discardableResult
    func disablePlugin(_ pluginId: String) -> Bool {
        // 卸载插件
        unloadPlugin(identifier: pluginId)

        // 加入禁用列表
        var disabled = disabledPluginIds
        disabled.insert(pluginId)
        disabledPluginIds = disabled

        return true
    }
}
