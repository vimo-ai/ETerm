//
//  SDKPluginLoader.swift
//  ETerm
//
//  SDK 插件加载器
//  负责加载使用 ETermKit SDK 开发的插件

import Foundation
import SwiftUI
import AppKit
import ETermKit
import Combine

/// SDK 插件加载结果
struct SDKPluginLoadResult {
    let manifest: PluginManifest
    let bundlePath: String
    let viewBundle: Bundle?
    let isLoaded: Bool
    let error: PluginError?
}

/// SDK 插件加载器
///
/// 职责：
/// - 扫描并加载 SDK 插件 Bundle
/// - 验证 Manifest 配置
/// - 依赖拓扑排序
/// - 与 ExtensionHostManager 协调加载插件逻辑
/// - 加载并缓存 ViewProvider（用于主进程渲染 View）
final class SDKPluginLoader {

    static let shared = SDKPluginLoader()

    // MARK: - Properties

    /// 已加载的插件 Manifest
    private var manifests: [String: PluginManifest] = [:]

    /// 插件 Bundle 路径 (pluginId -> bundlePath)
    private var bundlePaths: [String: String] = [:]

    /// 已加载的 Bundle (pluginId -> Bundle)
    private var loadedBundles: [String: Bundle] = [:]

    /// 已加载的 ViewProvider (pluginId -> PluginViewProvider)，仅 isolated 模式使用
    private var viewProviders: [String: any PluginViewProvider] = [:]

    /// 已加载的 Plugin 实例 (pluginId -> Plugin)，仅 main 模式使用
    private var mainModePlugins: [String: any ETermKit.Plugin] = [:]

    /// 已加载的 PluginHost (pluginId -> PluginHost)，统一接口
    private var pluginHosts: [String: any PluginHost] = [:]

    /// 加载失败的插件
    private var failedPlugins: [String: PluginError] = [:]

    /// 跳过的插件（依赖问题）
    private var skippedPlugins: [String: String] = [:]

    /// MenuBar 状态栏项 (pluginId -> NSStatusItem)
    private var menuBarItems: [String: NSStatusItem] = [:]

    // MARK: - Init

    private init() {
        setupRequestHandler()
    }

    /// 设置请求处理器，监听 View 发送的插件请求
    private func setupRequestHandler() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.PluginRequest"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handlePluginRequest(notification)
        }
    }

    /// 处理来自 View 的插件请求
    private func handlePluginRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let pluginId = userInfo["pluginId"] as? String,
              let requestId = userInfo["requestId"] as? String else {
            print("[SDKPluginLoader] Invalid plugin request notification")
            return
        }

        let params = userInfo["params"] as? [String: Any] ?? [:]

        print("[SDKPluginLoader] Forwarding request: \(pluginId).\(requestId)")

        Task {
            do {
                let result = try await ExtensionHostManager.shared.sendRequest(
                    pluginId: pluginId,
                    requestId: requestId,
                    params: params
                )
                print("[SDKPluginLoader] Request completed: \(result)")
            } catch {
                print("[SDKPluginLoader] Request failed: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// 加载所有 SDK 插件
    func loadAllPlugins() async {
        // 1. 扫描插件目录
        let pluginPaths = scanPluginDirectories()

        // 2. 读取所有 Manifest
        var pendingManifests: [PluginManifest] = []
        for path in pluginPaths {
            if let manifest = loadManifest(from: path) {
                pendingManifests.append(manifest)
            }
        }

        // 3. 检查是否有 isolated 模式插件，按需启动 Extension Host
        let hasIsolatedPlugins = pendingManifests.contains { $0.runMode == .isolated }
        if hasIsolatedPlugins {
            do {
                try await ExtensionHostManager.shared.start()
                print("[SDKPluginLoader] Extension Host started for isolated plugins")
            } catch {
                print("[SDKPluginLoader] Failed to start Extension Host: \(error)")
                // 继续加载 main 模式插件
            }
        }

        // 4. 拓扑排序
        let sortedManifests = topologicalSort(pendingManifests)

        // 5. 按顺序加载
        for manifest in sortedManifests {
            await loadPlugin(manifest)
        }

        let mainCount = mainModePlugins.count
        let isolatedCount = viewProviders.count
        print("[SDKPluginLoader] Loaded \(manifests.count) plugins (main: \(mainCount), isolated: \(isolatedCount)), \(failedPlugins.count) failed, \(skippedPlugins.count) skipped")
    }

    /// 获取所有已加载的插件信息
    func allPluginInfos() -> [PluginInfo] {
        return manifests.values.map { manifest in
            PluginInfo(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                dependencies: manifest.dependencies.map { $0.id },
                isLoaded: true,
                isEnabled: true,
                dependents: getDependents(of: manifest.id)
            )
        }
    }

    /// 获取插件 Manifest
    func getManifest(_ pluginId: String) -> PluginManifest? {
        return manifests[pluginId]
    }

    /// 获取插件 Bundle
    func getBundle(_ pluginId: String) -> Bundle? {
        return loadedBundles[pluginId]
    }

    /// 获取插件 ViewProvider（仅 isolated 模式）
    func getViewProvider(_ pluginId: String) -> PluginViewProvider? {
        return viewProviders[pluginId]
    }

    /// 获取插件 PluginHost（统一接口）
    func getPluginHost(_ pluginId: String) -> (any PluginHost)? {
        return pluginHosts[pluginId]
    }

    /// 获取所有 PluginHost
    func getAllPluginHosts() -> [String: any PluginHost] {
        return pluginHosts
    }

    // MARK: - Private

    /// 扫描插件目录
    private func scanPluginDirectories() -> [String] {
        var paths: [String] = []

        // 用户插件目录
        let userPluginsPath = ETermPaths.plugins
        paths.append(contentsOf: scanDirectory(userPluginsPath))

        // 开发插件目录（通过环境变量）
        if let devPath = ProcessInfo.processInfo.environment["ETERM_PLUGIN_PATH"] {
            paths.append(contentsOf: scanDirectory(devPath))
        }

        return paths
    }

    /// 扫描单个目录
    private func scanDirectory(_ path: String) -> [String] {
        var results: [String] = []

        guard FileManager.default.fileExists(atPath: path) else {
            return results
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)

            for item in contents {
                let itemPath = (path as NSString).appendingPathComponent(item)

                // 检查是否是 .bundle
                if item.hasSuffix(".bundle") {
                    results.append(itemPath)
                    continue
                }

                // 检查子目录中的 .bundle
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue {
                    let subContents = try? FileManager.default.contentsOfDirectory(atPath: itemPath)
                    for subItem in subContents ?? [] {
                        if subItem.hasSuffix(".bundle") {
                            results.append((itemPath as NSString).appendingPathComponent(subItem))
                        }
                    }
                }
            }
        } catch {
            print("[SDKPluginLoader] Failed to scan \(path): \(error)")
        }

        return results
    }

    /// 从 Bundle 加载 Manifest
    private func loadManifest(from bundlePath: String) -> PluginManifest? {
        let manifestPath = (bundlePath as NSString).appendingPathComponent("Contents/Resources/manifest.json")

        guard FileManager.default.fileExists(atPath: manifestPath) else {
            // 不是 SDK 插件，跳过
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            // 存储 bundle 路径以便激活时使用
            bundlePaths[manifest.id] = bundlePath
            return manifest
        } catch {
            print("[SDKPluginLoader] Failed to parse manifest at \(manifestPath): \(error)")
            failedPlugins[bundlePath] = .manifestParseError(reason: error.localizedDescription)
            return nil
        }
    }

    /// 拓扑排序（Kahn 算法）
    private func topologicalSort(_ manifests: [PluginManifest]) -> [PluginManifest] {
        // 构建 ID -> Manifest 映射
        var manifestMap: [String: PluginManifest] = [:]
        for m in manifests {
            manifestMap[m.id] = m
        }

        // 计算入度
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]

        for m in manifests {
            inDegree[m.id] = m.dependencies.count

            for dep in m.dependencies {
                dependents[dep.id, default: []].append(m.id)
            }
        }

        // BFS
        var queue = manifests.filter { inDegree[$0.id] == 0 }.map { $0.id }
        var result: [PluginManifest] = []

        while !queue.isEmpty {
            let id = queue.removeFirst()

            if let m = manifestMap[id] {
                result.append(m)

                for depId in dependents[id, default: []] {
                    inDegree[depId]! -= 1
                    if inDegree[depId] == 0 {
                        queue.append(depId)
                    }
                }
            }
        }

        // 检查循环依赖
        if result.count != manifests.count {
            let stuck = manifests.filter { !result.map { $0.id }.contains($0.id) }
            for m in stuck {
                print("[SDKPluginLoader] Circular dependency detected: \(m.id)")
                failedPlugins[m.id] = .circularDependency(pluginIds: [m.id])
            }
        }

        return result
    }

    /// 加载单个插件
    private func loadPlugin(_ manifest: PluginManifest) async {
        let pluginId = manifest.id

        // 检查依赖
        for dep in manifest.dependencies {
            if manifests[dep.id] == nil {
                skippedPlugins[pluginId] = "Missing dependency: \(dep.id)"
                print("[SDKPluginLoader] Skipping \(pluginId): missing dependency \(dep.id)")
                return
            }

            // 版本检查
            if let loadedManifest = manifests[dep.id] {
                if !isVersionCompatible(loadedManifest.version, minVersion: dep.minVersion) {
                    skippedPlugins[pluginId] = "Incompatible dependency version: \(dep.id)"
                    return
                }
            }
        }

        // 根据运行模式分支加载
        switch manifest.runMode {
        case .main:
            await loadMainModePlugin(manifest)
        case .isolated:
            await loadIsolatedModePlugin(manifest)
        }
    }

    /// 加载主进程模式插件
    private func loadMainModePlugin(_ manifest: PluginManifest) async {
        let pluginId = manifest.id

        guard let bundlePath = bundlePaths[pluginId] else {
            print("[SDKPluginLoader] Missing bundlePath for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Missing bundlePath")
            return
        }

        // 加载 Bundle
        guard let bundle = Bundle(path: bundlePath) else {
            print("[SDKPluginLoader] Failed to create bundle for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Failed to create bundle")
            return
        }

        do {
            try bundle.loadAndReturnError()
            loadedBundles[pluginId] = bundle
            print("[SDKPluginLoader] Loaded bundle for \(pluginId) (main mode)")
        } catch {
            print("[SDKPluginLoader] Failed to load bundle for \(pluginId): \(error)")
            failedPlugins[pluginId] = .activationFailed(reason: "Failed to load bundle: \(error.localizedDescription)")
            return
        }

        // 获取 Plugin 类
        let className = manifest.principalClass
        let classNames = [
            className,
            "\(bundle.bundleIdentifier ?? "").\(className)",
        ]

        var pluginInstance: (any ETermKit.Plugin)?
        for name in classNames {
            if let pluginClass = bundle.classNamed(name) as? NSObject.Type,
               let instance = pluginClass.init() as? any ETermKit.Plugin {
                pluginInstance = instance
                print("[SDKPluginLoader] Loaded Plugin '\(name)' for \(pluginId)")
                break
            }
            if let pluginClass = NSClassFromString(name) as? NSObject.Type,
               let instance = pluginClass.init() as? any ETermKit.Plugin {
                pluginInstance = instance
                print("[SDKPluginLoader] Loaded Plugin '\(name)' for \(pluginId)")
                break
            }
        }

        guard let plugin = pluginInstance else {
            print("[SDKPluginLoader] Failed to load Plugin class '\(className)' for \(pluginId), tried: \(classNames)")
            failedPlugins[pluginId] = .activationFailed(reason: "Plugin class not found: \(className)")
            return
        }

        // 激活插件
        let hostBridge = MainProcessHostBridge(pluginId: pluginId, manifest: manifest)
        plugin.activate(host: hostBridge)

        // 存储
        mainModePlugins[pluginId] = plugin
        manifests[pluginId] = manifest

        // 创建 PluginHost
        let pluginHost = MainModePluginHost(plugin: plugin, manifest: manifest)
        pluginHosts[pluginId] = pluginHost

        print("[SDKPluginLoader] Activated plugin: \(pluginId) (main mode)")

        // 注册 UI
        registerSidebarTabs(for: manifest)
        registerMenuBar(for: manifest)
        registerKeyBindings(for: manifest)
        registerInfoPanelContents(for: manifest)
        registerBottomDock(for: manifest)
        registerBubble(for: manifest)
    }

    /// 加载隔离模式插件
    private func loadIsolatedModePlugin(_ manifest: PluginManifest) async {
        let pluginId = manifest.id

        // 注册 Manifest
        manifests[pluginId] = manifest

        // 注册能力
        await ExtensionHostManager.shared.getBridge()?.registerManifest(manifest)

        guard let bundlePath = bundlePaths[pluginId] else {
            print("[SDKPluginLoader] Missing bundlePath for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Missing bundlePath")
            manifests.removeValue(forKey: pluginId)
            return
        }

        // 加载 Bundle（用于获取 ViewProvider）
        if let bundle = Bundle(path: bundlePath) {
            do {
                try bundle.loadAndReturnError()
                loadedBundles[pluginId] = bundle
                print("[SDKPluginLoader] Loaded bundle for \(pluginId) (isolated mode)")

                // 加载 ViewProvider
                if let viewProviderClassName = manifest.viewProviderClass {
                    loadViewProvider(pluginId: pluginId, className: viewProviderClassName, bundle: bundle)
                }
            } catch {
                print("[SDKPluginLoader] Failed to load bundle for \(pluginId): \(error)")
                failedPlugins[pluginId] = .activationFailed(reason: "Failed to load bundle: \(error.localizedDescription)")
                manifests.removeValue(forKey: pluginId)
                return
            }
        } else {
            print("[SDKPluginLoader] Failed to create bundle for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Failed to create bundle")
            manifests.removeValue(forKey: pluginId)
            return
        }

        do {
            try await ExtensionHostManager.shared.getBridge()?.activatePlugin(
                pluginId: pluginId,
                bundlePath: bundlePath,
                manifest: manifest
            )
            print("[SDKPluginLoader] Activated plugin: \(pluginId) (isolated mode)")

            // 创建 PluginHost
            let pluginHost = IsolatedModePluginHost(
                viewProvider: viewProviders[pluginId],
                manifest: manifest
            )
            pluginHosts[pluginId] = pluginHost

            // 注册 UI
            registerSidebarTabs(for: manifest)
            registerMenuBar(for: manifest)
            registerKeyBindings(for: manifest)
            registerInfoPanelContents(for: manifest)
            registerBottomDock(for: manifest)
            registerBubble(for: manifest)
        } catch {
            print("[SDKPluginLoader] Failed to activate \(pluginId): \(error)")
            failedPlugins[pluginId] = .activationFailed(reason: error.localizedDescription)
            manifests.removeValue(forKey: pluginId)
        }
    }

    /// 加载 ViewProvider
    private func loadViewProvider(pluginId: String, className: String, bundle: Bundle) {
        // 尝试多种类名格式
        let classNames = [
            className,
            "\(bundle.bundleIdentifier ?? "").\(className)",
        ]

        for name in classNames {
            // 方式 1: 通过 Bundle.classNamed
            if let providerClass = bundle.classNamed(name) as? NSObject.Type,
               let provider = providerClass.init() as? PluginViewProvider {
                viewProviders[pluginId] = provider
                print("[SDKPluginLoader] Loaded ViewProvider '\(name)' for \(pluginId)")
                return
            }

            // 方式 2: 通过 NSClassFromString
            if let providerClass = NSClassFromString(name) as? NSObject.Type,
               let provider = providerClass.init() as? PluginViewProvider {
                viewProviders[pluginId] = provider
                print("[SDKPluginLoader] Loaded ViewProvider '\(name)' for \(pluginId)")
                return
            }
        }

        print("[SDKPluginLoader] Failed to load ViewProvider '\(className)' for \(pluginId), tried: \(classNames)")
    }

    /// 版本兼容性检查
    private func isVersionCompatible(_ version: String, minVersion: String) -> Bool {
        let vParts = version.split(separator: ".").compactMap { Int($0) }
        let mParts = minVersion.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(vParts.count, mParts.count) {
            let v = i < vParts.count ? vParts[i] : 0
            let m = i < mParts.count ? mParts[i] : 0

            if v > m { return true }
            if v < m { return false }
        }

        return true  // 版本相等
    }

    /// 获取依赖指定插件的所有插件 ID
    private func getDependents(of pluginId: String) -> [String] {
        return manifests.values.compactMap { manifest in
            manifest.dependencies.contains { $0.id == pluginId } ? manifest.id : nil
        }
    }

    /// 注册 SDK 插件的 sidebarTabs 到 SidebarRegistry
    private func registerSidebarTabs(for manifest: PluginManifest) {
        guard !manifest.sidebarTabs.isEmpty else { return }

        let pluginId = manifest.id

        for tabConfig in manifest.sidebarTabs {
            // 检查渲染模式
            let isTabMode = tabConfig.renderMode == "tab"

            if isTabMode {
                // Tab 模式：点击后创建 View Tab
                let tab = SidebarTab(
                    id: tabConfig.id,
                    title: tabConfig.title,
                    icon: tabConfig.icon,
                    viewProvider: { AnyView(EmptyView()) },
                    onSelect: { [weak self] in
                        // 预注册视图 Provider（用于 Session 恢复）
                        UIServiceImpl.shared.registerViewProvider(
                            for: pluginId,
                            viewId: tabConfig.id,
                            title: tabConfig.title
                        ) {
                            if let viewProvider = self?.viewProviders[pluginId] {
                                return viewProvider.view(for: tabConfig.id)
                            }
                            return AnyView(SDKPluginPlaceholderView(
                                pluginId: pluginId,
                                tabId: tabConfig.id,
                                message: "ViewProvider not loaded"
                            ))
                        }

                        // 创建或切换到 View Tab
                        UIServiceImpl.shared.createViewTab(
                            for: pluginId,
                            viewId: tabConfig.id,
                            title: tabConfig.title,
                            placement: .split(.horizontal)
                        ) {
                            if let viewProvider = self?.viewProviders[pluginId] {
                                return viewProvider.view(for: tabConfig.id)
                            }
                            return AnyView(SDKPluginPlaceholderView(
                                pluginId: pluginId,
                                tabId: tabConfig.id,
                                message: "ViewProvider not loaded"
                            ))
                        }
                    }
                )

                SidebarRegistry.shared.registerTab(
                    for: manifest.id,
                    pluginName: manifest.name,
                    tab: tab
                )

                print("[SDKPluginLoader] Registered sidebar tab '\(tabConfig.id)' for \(manifest.id) (tab mode)")
            } else {
                // Inline 模式：直接在 sidebar 里渲染
                let tab = SidebarTab(
                    id: tabConfig.id,
                    title: tabConfig.title,
                    icon: tabConfig.icon
                ) { [weak self] in
                    // 优先使用 ViewProvider 获取 View
                    if let viewProvider = self?.viewProviders[pluginId] {
                        return viewProvider.view(for: tabConfig.id)
                    }

                    // 回退：使用通用的占位视图
                    return AnyView(SDKPluginPlaceholderView(
                        pluginId: pluginId,
                        tabId: tabConfig.id,
                        message: "ViewProvider not loaded"
                    ))
                }

                SidebarRegistry.shared.registerTab(
                    for: manifest.id,
                    pluginName: manifest.name,
                    tab: tab
                )

                print("[SDKPluginLoader] Registered sidebar tab '\(tabConfig.id)' for \(manifest.id) (inline mode)")
            }
        }
    }

    /// 注册 SDK 插件的 MenuBar 到系统状态栏
    private func registerMenuBar(for manifest: PluginManifest) {
        guard let config = manifest.menuBar else { return }

        // 获取或创建 ViewProvider
        let provider = getOrCreateViewProvider(for: manifest)
        guard let provider = provider else {
            print("[SDKPluginLoader] No ViewProvider for \(manifest.id), skipping MenuBar registration")
            return
        }

        // 获取 MenuBar 视图
        guard let menuBarView = provider.createMenuBarView() else {
            print("[SDKPluginLoader] ViewProvider for \(manifest.id) does not provide MenuBar view")
            return
        }

        // 创建 NSStatusItem
        let statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(config.width))

        // 使用 NSHostingView 嵌入 SwiftUI 视图
        if let button = statusItem.button {
            let hostingView = NSHostingView(rootView: menuBarView)
            hostingView.frame = button.bounds
            hostingView.autoresizingMask = [.width, .height]
            button.addSubview(hostingView)
        }

        menuBarItems[manifest.id] = statusItem
        print("[SDKPluginLoader] Registered menuBar '\(config.id)' for \(manifest.id)")
    }

    /// 获取或创建 ViewProvider 实例
    private func getOrCreateViewProvider(for manifest: PluginManifest) -> (any PluginViewProvider)? {
        // 如果已有实例，直接返回
        if let existing = viewProviders[manifest.id] {
            return existing
        }

        // 需要 viewProviderClass 才能创建
        guard let viewProviderClassName = manifest.viewProviderClass,
              let bundlePath = bundlePaths[manifest.id] else {
            return nil
        }

        // 加载插件 Bundle
        guard let bundle = Bundle(path: bundlePath), bundle.load() else {
            print("[SDKPluginLoader] Failed to load bundle at \(bundlePath)")
            return nil
        }

        // 获取 ViewProvider 类
        // 尝试多种类名格式
        let classNames = [
            viewProviderClassName,
            "\(manifest.name).\(viewProviderClassName)",
            "\(manifest.id.replacingOccurrences(of: ".", with: "_")).\(viewProviderClassName)"
        ]

        var viewProviderClass: (any PluginViewProvider.Type)?
        for className in classNames {
            if let cls = NSClassFromString(className) as? any PluginViewProvider.Type {
                viewProviderClass = cls
                break
            }
        }

        guard let providerClass = viewProviderClass else {
            print("[SDKPluginLoader] ViewProvider class '\(viewProviderClassName)' not found for \(manifest.id)")
            return nil
        }

        // 创建实例
        let provider = providerClass.init()
        viewProviders[manifest.id] = provider
        return provider
    }

    /// 注册 SDK 插件的 keyBindings 到 KeyboardService
    private func registerKeyBindings(for manifest: PluginManifest) {
        guard !manifest.commands.isEmpty else { return }

        let pluginId = manifest.id

        for command in manifest.commands {
            // 只处理有 keyBinding 的命令
            guard let keyBindingStr = command.keyBinding else { continue }

            // 解析 keyBinding 字符串为 KeyStroke
            guard let keyStroke = parseKeyBinding(keyBindingStr) else {
                print("[SDKPluginLoader] Failed to parse keyBinding \(keyBindingStr) for command \(command.id)")
                continue
            }

            // 注册快捷键到 KeyboardService
            KeyboardServiceImpl.shared.bind(keyStroke, to: command.id, when: nil)

            print("[SDKPluginLoader] Registered keyBinding \(keyBindingStr) -> \(command.id) for \(pluginId)")
        }
    }

    /// 解析 keyBinding 字符串为 KeyStroke
    /// 支持格式："cmd+shift+o", "ctrl+a", "option+1", "cmd+/"
    private func parseKeyBinding(_ str: String) -> KeyStroke? {
        let parts = str.lowercased().split(separator: "+").map { String($0) }
        guard !parts.isEmpty else { return nil }

        var modifiers: KeyModifiers = []
        var character: String?

        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "shift":
                modifiers.insert(.shift)
            case "option", "opt", "alt":
                modifiers.insert(.option)
            default:
                character = part
            }
        }

        guard let char = character else { return nil }

        return KeyStroke(
            keyCode: 0,
            character: char,
            actualCharacter: nil,
            modifiers: modifiers
        )
    }

    // MARK: - Info Panel Registration

    /// 注册 SDK 插件的 infoPanelContents 到 InfoWindowRegistry
    private func registerInfoPanelContents(for manifest: PluginManifest) {
        guard !manifest.infoPanelContents.isEmpty else { return }

        let pluginId = manifest.id

        for content in manifest.infoPanelContents {
            // 使用 content.id 作为注册 id（不加 pluginId 前缀）
            // 这样 SDK 插件可以替代内置插件的注册
            InfoWindowRegistry.shared.registerContent(
                id: content.id,
                title: content.title
            ) { [weak self] in
                if let provider = self?.viewProviders[pluginId] {
                    return provider.createInfoPanelView(id: content.id) ?? AnyView(
                        Text("InfoPanel view not provided")
                            .foregroundColor(.secondary)
                    )
                }
                return AnyView(
                    Text("ViewProvider not loaded")
                        .foregroundColor(.secondary)
                )
            }

            print("[SDKPluginLoader] Registered infoPanelContent '\(content.id)' for \(pluginId)")
        }
    }

    // MARK: - Bottom Dock Registration

    /// 已注册的 bottomDock 配置 (pluginId -> config)
    private static var bottomDockConfigs: [String: PluginManifest.BottomDockConfig] = [:]

    /// 注册 SDK 插件的 bottomDock 命令关联
    private func registerBottomDock(for manifest: PluginManifest) {
        guard let config = manifest.bottomDock else { return }

        let pluginId = manifest.id

        // 存储配置供后续使用
        SDKPluginLoader.bottomDockConfigs[pluginId] = config

        // 注册命令到 CommandRegistry
        // 注意：命令 ID 使用 manifest.commands 中定义的 ID
        // 这里只是确保命令存在并绑定到 bottomDock 操作

        if let toggleCmd = config.toggleCommand {
            let command = Command(
                id: toggleCmd,
                title: "切换 \(manifest.name)",
                icon: "rectangle.bottomhalf.filled"
            ) { [weak self] _ in
                self?.toggleBottomDock(pluginId: pluginId)
            }
            CommandRegistry.shared.register(command)
            print("[SDKPluginLoader] Registered bottomDock toggle command '\(toggleCmd)' for \(pluginId)")
        }

        if let showCmd = config.showCommand {
            let command = Command(
                id: showCmd,
                title: "显示 \(manifest.name)",
                icon: "rectangle.bottomhalf.filled"
            ) { [weak self] _ in
                self?.showBottomDock(pluginId: pluginId)
            }
            CommandRegistry.shared.register(command)
            print("[SDKPluginLoader] Registered bottomDock show command '\(showCmd)' for \(pluginId)")
        }

        if let hideCmd = config.hideCommand {
            let command = Command(
                id: hideCmd,
                title: "隐藏 \(manifest.name)",
                icon: "rectangle.bottomhalf.filled"
            ) { [weak self] _ in
                self?.hideBottomDock(pluginId: pluginId)
            }
            CommandRegistry.shared.register(command)
            print("[SDKPluginLoader] Registered bottomDock hide command '\(hideCmd)' for \(pluginId)")
        }
    }

    /// 显示插件的 bottomDock
    func showBottomDock(pluginId: String) {
        guard let config = SDKPluginLoader.bottomDockConfigs[pluginId],
              let provider = viewProviders[pluginId],
              let view = provider.createBottomDockView(id: config.id) else {
            print("[SDKPluginLoader] Cannot show bottomDock for \(pluginId): config or view not available")
            return
        }

        // 通过 Notification 通知 RioTerminalView 显示 bottomDock
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.ShowBottomDock"),
            object: nil,
            userInfo: [
                "pluginId": pluginId,
                "dockId": config.id,
                "view": view
            ]
        )
    }

    /// 隐藏插件的 bottomDock
    func hideBottomDock(pluginId: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.HideBottomDock"),
            object: nil,
            userInfo: ["pluginId": pluginId]
        )
    }

    /// 切换插件的 bottomDock 显示状态
    func toggleBottomDock(pluginId: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.ToggleBottomDock"),
            object: nil,
            userInfo: ["pluginId": pluginId]
        )
    }

    // MARK: - Bubble Registration

    /// 已注册的 bubble 配置 (pluginId -> config)
    private static var bubbleConfigs: [String: PluginManifest.BubbleConfig] = [:]

    /// 注册 SDK 插件的 bubble 配置
    private func registerBubble(for manifest: PluginManifest) {
        guard let config = manifest.bubble else { return }

        let pluginId = manifest.id

        // 存储配置
        SDKPluginLoader.bubbleConfigs[pluginId] = config

        // 订阅触发事件（通过 EventBus）
        // 注意：实际的事件订阅在 ExtensionHost 端处理，这里只是注册配置
        // TranslationController 会查询这些配置来决定如何处理

        print("[SDKPluginLoader] Registered bubble '\(config.id)' for \(pluginId), trigger: \(config.trigger)")
    }

    /// 获取已注册的 bubble 配置
    static func getBubbleConfig(for pluginId: String) -> PluginManifest.BubbleConfig? {
        return bubbleConfigs[pluginId]
    }

    /// 获取所有已注册的 bubble 配置
    static func getAllBubbleConfigs() -> [String: PluginManifest.BubbleConfig] {
        return bubbleConfigs
    }

    /// 获取已加载的所有 Manifest
    func getLoadedManifests() -> [String: PluginManifest] {
        return manifests
    }

    /// 获取 bubble 内容视图
    func getBubbleContentView(pluginId: String, bubbleId: String) -> AnyView? {
        guard let provider = viewProviders[pluginId] else { return nil }
        return provider.createBubbleContentView(id: bubbleId)
    }
}
