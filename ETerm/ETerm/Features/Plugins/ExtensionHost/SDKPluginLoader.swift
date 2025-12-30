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

    /// 已加载的 HostBridge 实例 (pluginId -> HostBridge)，保持强引用避免被释放
    private var hostBridges: [String: any ETermKit.HostBridge] = [:]

    /// 已加载的 PluginHost (pluginId -> PluginHost)，统一接口
    private var pluginHosts: [String: any PluginHost] = [:]

    /// 加载失败的插件
    private var failedPlugins: [String: PluginError] = [:]

    /// 跳过的插件（依赖问题）
    private var skippedPlugins: [String: String] = [:]

    /// MenuBar 状态栏项 (pluginId -> NSStatusItem)
    private var menuBarItems: [String: NSStatusItem] = [:]

    /// 禁用的插件 ID 集合（持久化）
    private var disabledPluginIds: Set<String> {
        get { loadDisabledPlugins() }
        set { saveDisabledPlugins(newValue) }
    }

    /// 配置文件路径
    private let configFilePath = ETermPaths.sdkPluginsConfig

    // MARK: - Init

    private init() {
        setupRequestHandler()
    }

    // MARK: - 持久化

    /// SDK 插件配置数据模型
    private struct SDKPluginsConfig: Codable {
        var disabledPlugins: [String]
    }

    /// 从 JSON 文件加载禁用的插件列表
    private func loadDisabledPlugins() -> Set<String> {
        guard FileManager.default.fileExists(atPath: configFilePath) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configFilePath))
            let config = try JSONDecoder().decode(SDKPluginsConfig.self, from: data)
            return Set(config.disabledPlugins)
        } catch {
            logError("[SDKPluginLoader] 加载配置失败: \(error)")
            return []
        }
    }

    /// 保存禁用的插件列表到 JSON 文件
    private func saveDisabledPlugins(_ disabledPlugins: Set<String>) {
        do {
            try ETermPaths.ensureParentDirectory(for: configFilePath)

            let config = SDKPluginsConfig(disabledPlugins: Array(disabledPlugins).sorted())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            logError("[SDKPluginLoader] 保存配置失败: \(error)")
        }
    }

    /// 注入嵌入终端工厂
    private func setupEmbeddedTerminalFactory() {
        EmbeddedTerminalFactory.createView = { terminalId, cwd in
            // 创建 EmbeddedTerminalMetalView
            let view = EmbeddedTerminalMetalView()
            view.workingDirectory = cwd
            view.onTerminalCreated = { id in
                // 更新 terminalId 映射（可选，用于后续控制）
                logInfo("[SDKPluginLoader] Embedded terminal created: \(id) for placeholder: \(terminalId)")
            }
            return view
        }
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
            logWarn("[SDKPluginLoader] Invalid plugin request notification")
            return
        }

        let params = userInfo["params"] as? [String: Any] ?? [:]

        Task {
            do {
                _ = try await ExtensionHostManager.shared.sendRequest(
                    pluginId: pluginId,
                    requestId: requestId,
                    params: params
                )
            } catch {
                logError("[SDKPluginLoader] Request failed: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// 缓存的待加载 Manifest（扫描后保存，供分阶段加载使用）
    private var pendingManifests: [PluginManifest] = []

    /// 扫描并解析所有插件 Manifest（第一步，必须先调用）
    func scanAndParseManifests() {
        let start = CFAbsoluteTimeGetCurrent()

        // 注入嵌入终端工厂
        setupEmbeddedTerminalFactory()

        // 扫描外部插件目录
        let pluginPaths = scanPluginDirectories()

        // 读取 Manifest
        pendingManifests = []
        for path in pluginPaths {
            if let manifest = loadManifest(from: path) {
                pendingManifests.append(manifest)
            }
        }

        logInfo("[SDKPluginLoader] Total plugins: \(pendingManifests.count)")
    }

    /// 加载 immediate 优先级的插件（窗口创建前同步调用）
    func loadImmediatePlugins() async {
        let immediateManifests = pendingManifests.filter { $0.loadPriority == .immediate }
        guard !immediateManifests.isEmpty else { return }

        // 检查是否有 isolated 模式插件
        let hasIsolatedPlugins = immediateManifests.contains { $0.runMode == .isolated }
        if hasIsolatedPlugins {
            do {
                try await ExtensionHostManager.shared.start()
            } catch {
                logError("[SDKPluginLoader] Extension Host FAILED: \(error)")
            }
        }

        // 拓扑排序并加载
        let layers = topologicalSortLayered(immediateManifests)
        for layer in layers {
            await withTaskGroup(of: Void.self) { group in
                for manifest in layer {
                    group.addTask {
                        await self.loadPlugin(manifest)
                    }
                }
            }
        }
    }

    /// 加载 background 优先级的插件（窗口创建后异步调用）
    func loadBackgroundPlugins() async {
        let backgroundManifests = pendingManifests.filter { $0.loadPriority == .background }
        guard !backgroundManifests.isEmpty else { return }

        // 检查是否有 isolated 模式插件需要启动 Extension Host
        let hasIsolatedPlugins = backgroundManifests.contains { $0.runMode == .isolated }
        let hostRunning = await ExtensionHostManager.shared.isRunning
        if hasIsolatedPlugins && !hostRunning {
            do {
                try await ExtensionHostManager.shared.start()
            } catch {
                logError("[SDKPluginLoader] Extension Host FAILED: \(error)")
            }
        }

        // 拓扑排序（分层）并发加载
        let layers = topologicalSortLayered(backgroundManifests)
        for layer in layers {
            await withTaskGroup(of: Void.self) { group in
                for manifest in layer {
                    group.addTask {
                        await self.loadPlugin(manifest)
                    }
                }
            }
        }
    }

    /// 加载所有 SDK 插件（兼容接口，一次性加载所有插件）
    func loadAllPlugins() async {
        scanAndParseManifests()
        await loadImmediatePlugins()
        await loadBackgroundPlugins()
    }

    /// 获取所有插件信息（包括已加载和已禁用的）
    func allPluginInfos() -> [PluginInfo] {
        // 从 pendingManifests 获取所有扫描到的插件（包括禁用的）
        var allManifests = pendingManifests
        // 加上已加载的（避免重复）
        for manifest in manifests.values where !allManifests.contains(where: { $0.id == manifest.id }) {
            allManifests.append(manifest)
        }

        return allManifests.map { manifest in
            let isEnabled = !disabledPluginIds.contains(manifest.id)
            let isLoaded = manifests[manifest.id] != nil
            return PluginInfo(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                dependencies: manifest.dependencies.map { $0.id },
                isLoaded: isLoaded,
                isEnabled: isEnabled,
                dependents: getDependents(of: manifest.id)
            )
        }
    }

    // MARK: - 热插拔 API

    /// 检查插件是否启用
    func isPluginEnabled(_ pluginId: String) -> Bool {
        !disabledPluginIds.contains(pluginId)
    }

    /// 检查插件是否已加载
    func isPluginLoaded(_ pluginId: String) -> Bool {
        manifests[pluginId] != nil
    }

    /// 启用插件（热加载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @MainActor
    @discardableResult
    func enablePlugin(_ pluginId: String) async -> Bool {
        // 从 pendingManifests 中找到 manifest
        guard let manifest = pendingManifests.first(where: { $0.id == pluginId }) else {
            logWarn("[SDKPluginLoader] Cannot enable \(pluginId): manifest not found")
            return false
        }

        // 先启用依赖
        for dep in manifest.dependencies {
            if disabledPluginIds.contains(dep.id) {
                let success = await enablePlugin(dep.id)
                if !success {
                    logWarn("[SDKPluginLoader] Cannot enable \(pluginId): dependency \(dep.id) failed to enable")
                    return false
                }
            }
        }

        // 从禁用列表移除
        var disabled = disabledPluginIds
        disabled.remove(pluginId)
        disabledPluginIds = disabled

        // 加载插件
        await loadPlugin(manifest)

        logInfo("[SDKPluginLoader] Enabled plugin: \(pluginId)")
        return manifests[pluginId] != nil
    }

    /// 禁用插件（热卸载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @MainActor
    @discardableResult
    func disablePlugin(_ pluginId: String) -> Bool {
        // 先禁用依赖此插件的其他插件
        let dependents = getDependents(of: pluginId)
        for depId in dependents {
            if manifests[depId] != nil {
                if !disablePlugin(depId) {
                    logWarn("[SDKPluginLoader] Cannot disable \(pluginId): dependent \(depId) failed to disable")
                    return false
                }
            }
        }

        // 卸载插件
        unloadPlugin(pluginId)

        // 加入禁用列表
        var disabled = disabledPluginIds
        disabled.insert(pluginId)
        disabledPluginIds = disabled

        logInfo("[SDKPluginLoader] Disabled plugin: \(pluginId)")
        return true
    }

    /// 卸载插件（注销 UI 组件，但不改变启用状态）
    private func unloadPlugin(_ pluginId: String) {
        guard manifests[pluginId] != nil else { return }

        // 注销侧边栏 Tab
        SidebarRegistry.shared.unregisterTabs(for: pluginId)

        // 注销 View Tab 视图定义
        ViewTabRegistry.shared.unregisterAll(for: pluginId)

        // 注销 PageBar 组件
        PageBarItemRegistry.shared.unregisterItems(for: pluginId)

        // 注销 Tab Slot
        tabSlotRegistry.unregister(pluginId: pluginId)

        // 注销 Page Slot
        pageSlotRegistry.unregister(pluginId: pluginId)

        // 注销 Info Panel
        if let manifest = manifests[pluginId] {
            for content in manifest.infoPanelContents {
                InfoWindowRegistry.shared.unregisterContent(id: content.id)
            }
        }

        // 移除 MenuBar
        if let statusItem = menuBarItems[pluginId] {
            NSStatusBar.system.removeStatusItem(statusItem)
            menuBarItems.removeValue(forKey: pluginId)
        }

        // main mode: 调用 deactivate
        if let plugin = mainModePlugins[pluginId] {
            plugin.deactivate()
            mainModePlugins.removeValue(forKey: pluginId)
        }

        // 清理存储
        hostBridges.removeValue(forKey: pluginId)
        pluginHosts.removeValue(forKey: pluginId)
        viewProviders.removeValue(forKey: pluginId)
        loadedBundles.removeValue(forKey: pluginId)
        manifests.removeValue(forKey: pluginId)

        logInfo("[SDKPluginLoader] Unloaded plugin: \(pluginId)")
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
            logError("[SDKPluginLoader] Failed to scan \(path): \(error)")
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
            logError("[SDKPluginLoader] Failed to parse manifest at \(manifestPath): \(error)")
            failedPlugins[bundlePath] = .manifestParseError(reason: error.localizedDescription)
            return nil
        }
    }

    /// 拓扑排序（Kahn 算法）- 返回分层结构，每层可并发加载
    private func topologicalSortLayered(_ manifests: [PluginManifest]) -> [[PluginManifest]] {
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

        // 分层 BFS
        var currentLayer = manifests.filter { inDegree[$0.id] == 0 }.map { $0.id }
        var layers: [[PluginManifest]] = []
        var processed = Set<String>()

        while !currentLayer.isEmpty {
            // 当前层的 Manifest
            let layerManifests = currentLayer.compactMap { manifestMap[$0] }
            if !layerManifests.isEmpty {
                layers.append(layerManifests)
            }

            // 标记已处理
            for id in currentLayer {
                processed.insert(id)
            }

            // 找下一层
            var nextLayer: [String] = []
            for id in currentLayer {
                for depId in dependents[id, default: []] {
                    inDegree[depId]! -= 1
                    if inDegree[depId] == 0 && !processed.contains(depId) {
                        nextLayer.append(depId)
                    }
                }
            }

            currentLayer = nextLayer
        }

        // 检查循环依赖
        let totalProcessed = layers.flatMap { $0 }.count
        if totalProcessed != manifests.count {
            let stuck = manifests.filter { !processed.contains($0.id) }
            for m in stuck {
                logError("[SDKPluginLoader] Circular dependency detected: \(m.id)")
                failedPlugins[m.id] = .circularDependency(pluginIds: [m.id])
            }
        }

        return layers
    }

    /// 加载单个插件
    private func loadPlugin(_ manifest: PluginManifest) async {
        let pluginId = manifest.id

        // 检查是否禁用
        if disabledPluginIds.contains(pluginId) {
            logInfo("[SDKPluginLoader] Skipping disabled plugin: \(pluginId)")
            return
        }

        // 检查依赖
        for dep in manifest.dependencies {
            if manifests[dep.id] == nil {
                skippedPlugins[pluginId] = "Missing dependency: \(dep.id)"
                logWarn("[SDKPluginLoader] Skipping \(pluginId): missing dependency \(dep.id)")
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
        let start = CFAbsoluteTimeGetCurrent()
        func elapsed() -> String {
            String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        // 加载 Bundle
        guard let bundlePath = bundlePaths[pluginId] else {
            logError("[SDKPluginLoader] Missing bundlePath for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Missing bundlePath")
            return
        }

        // 加载 Bundle
        guard let bundle = Bundle(path: bundlePath) else {
            logError("[SDKPluginLoader] Failed to create bundle for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Failed to create bundle")
            return
        }
        do {
            try bundle.loadAndReturnError()
            loadedBundles[pluginId] = bundle
        } catch {
            logError("[SDKPluginLoader] Failed to load bundle for \(pluginId): \(error)")
            failedPlugins[pluginId] = .activationFailed(reason: "Failed to load bundle: \(error.localizedDescription)")
            return
        }

        // 获取 Plugin 类
        let className = manifest.principalClass
        var pluginClass: NSObject.Type?

        if let cls = bundle.classNamed(className) as? NSObject.Type {
            pluginClass = cls
        } else if let cls = NSClassFromString(className) as? NSObject.Type {
            pluginClass = cls
        } else if let cls = bundle.principalClass as? NSObject.Type {
            pluginClass = cls
        }

        guard let cls = pluginClass else {
            logError("[SDKPluginLoader] Failed to find Plugin class '\(className)' for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Plugin class not found: \(className)")
            return
        }

        // 创建实例
        let instance = cls.init()

        guard let plugin = instance as? any ETermKit.Plugin else {
            logError("[SDKPluginLoader] Instance '\(type(of: instance))' does not conform to ETermKit.Plugin for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Plugin does not conform to ETermKit.Plugin")
            return
        }

        // 激活插件
        let hostBridge = MainProcessHostBridge(pluginId: pluginId, manifest: manifest)
        plugin.activate(host: hostBridge)

        // 存储
        hostBridges[pluginId] = hostBridge
        mainModePlugins[pluginId] = plugin
        manifests[pluginId] = manifest

        // 创建 PluginHost
        let pluginHost = MainModePluginHost(plugin: plugin, manifest: manifest)
        pluginHosts[pluginId] = pluginHost

        // 注册 UI（需要在主线程，因为 Registry 有 @Published）
        await MainActor.run {
            registerSidebarTabs(for: manifest)
            registerMenuBar(for: manifest)
            registerKeyBindings(for: manifest)
            registerInfoPanelContents(for: manifest)
            registerBottomDock(for: manifest)
            registerBubble(for: manifest)
            registerPageBarItems(for: manifest)
            registerTabSlots(for: manifest)
            registerPageSlots(for: manifest)
        }
    }

    /// 加载隔离模式插件
    private func loadIsolatedModePlugin(_ manifest: PluginManifest) async {
        let pluginId = manifest.id

        // 注册 Manifest
        manifests[pluginId] = manifest

        // 注册能力
        await ExtensionHostManager.shared.getBridge()?.registerManifest(manifest)

        guard let bundlePath = bundlePaths[pluginId] else {
            logError("[SDKPluginLoader] Missing bundlePath for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Missing bundlePath")
            manifests.removeValue(forKey: pluginId)
            return
        }

        // 加载 Bundle（用于获取 ViewProvider）
        if let bundle = Bundle(path: bundlePath) {
            do {
                try bundle.loadAndReturnError()
                loadedBundles[pluginId] = bundle

                // 加载 ViewProvider
                if let viewProviderClassName = manifest.viewProviderClass {
                    loadViewProvider(pluginId: pluginId, className: viewProviderClassName, bundle: bundle)
                }
            } catch {
                logError("[SDKPluginLoader] Failed to load bundle for \(pluginId): \(error)")
                failedPlugins[pluginId] = .activationFailed(reason: "Failed to load bundle: \(error.localizedDescription)")
                manifests.removeValue(forKey: pluginId)
                return
            }
        } else {
            logError("[SDKPluginLoader] Failed to create bundle for \(pluginId)")
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

            // 创建 PluginHost
            let pluginHost = IsolatedModePluginHost(
                viewProvider: viewProviders[pluginId],
                manifest: manifest
            )
            pluginHosts[pluginId] = pluginHost

            logInfo("[SDKPluginLoader] Activated isolated-mode plugin: \(pluginId)")

            // 注册 UI（需要在主线程，因为 Registry 有 @Published）
            await MainActor.run {
                registerSidebarTabs(for: manifest)
                registerMenuBar(for: manifest)
                registerKeyBindings(for: manifest)
                registerInfoPanelContents(for: manifest)
                registerBottomDock(for: manifest)
                registerBubble(for: manifest)
                registerPageBarItems(for: manifest)
                registerTabSlots(for: manifest)
                registerPageSlots(for: manifest)
            }
        } catch {
            logError("[SDKPluginLoader] Failed to activate \(pluginId): \(error)")
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
                return
            }

            // 方式 2: 通过 NSClassFromString
            if let providerClass = NSClassFromString(name) as? NSObject.Type,
               let provider = providerClass.init() as? PluginViewProvider {
                viewProviders[pluginId] = provider
                return
            }
        }

        logWarn("[SDKPluginLoader] Failed to load ViewProvider '\(className)' for \(pluginId), tried: \(classNames)")
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
        let isMainMode = manifest.runMode == .main

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
                            self?.getSidebarView(pluginId: pluginId, tabId: tabConfig.id, isMainMode: isMainMode)
                                ?? AnyView(SDKPluginPlaceholderView(
                                    pluginId: pluginId,
                                    tabId: tabConfig.id,
                                    message: "View not available"
                                ))
                        }

                        // 创建或切换到 View Tab
                        UIServiceImpl.shared.createViewTab(
                            for: pluginId,
                            viewId: tabConfig.id,
                            title: tabConfig.title,
                            placement: .split(.horizontal)
                        ) {
                            self?.getSidebarView(pluginId: pluginId, tabId: tabConfig.id, isMainMode: isMainMode)
                                ?? AnyView(SDKPluginPlaceholderView(
                                    pluginId: pluginId,
                                    tabId: tabConfig.id,
                                    message: "View not available"
                                ))
                        }
                    }
                )

                SidebarRegistry.shared.registerTab(
                    for: manifest.id,
                    pluginName: manifest.name,
                    tab: tab
                )
            } else {
                // Inline 模式：直接在 sidebar 里渲染
                let tab = SidebarTab(
                    id: tabConfig.id,
                    title: tabConfig.title,
                    icon: tabConfig.icon
                ) { [weak self] in
                    self?.getSidebarView(pluginId: pluginId, tabId: tabConfig.id, isMainMode: isMainMode)
                        ?? AnyView(SDKPluginPlaceholderView(
                            pluginId: pluginId,
                            tabId: tabConfig.id,
                            message: "View not available"
                        ))
                }

                SidebarRegistry.shared.registerTab(
                    for: manifest.id,
                    pluginName: manifest.name,
                    tab: tab
                )
            }
        }
    }

    /// 获取侧边栏视图（区分 main/isolated 模式）
    private func getSidebarView(pluginId: String, tabId: String, isMainMode: Bool) -> AnyView? {
        if isMainMode {
            // main mode: 使用 Plugin.sidebarView(for:)
            return mainModePlugins[pluginId]?.sidebarView(for: tabId)
        } else {
            // isolated mode: 使用 ViewProvider.view(for:)
            return viewProviders[pluginId]?.view(for: tabId)
        }
    }

    /// 注册 SDK 插件的 MenuBar 到系统状态栏
    private func registerMenuBar(for manifest: PluginManifest) {
        guard let config = manifest.menuBar else { return }

        // 获取或创建 ViewProvider
        guard let provider = getOrCreateViewProvider(for: manifest),
              let menuBarView = provider.createMenuBarView() else {
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
            logWarn("[SDKPluginLoader] ViewProvider class '\(viewProviderClassName)' not found for \(manifest.id)")
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

        for cmdConfig in manifest.commands {
            // 注册 Command 到 CommandRegistry（无论有无快捷键）
            let command = Command(
                id: cmdConfig.id,
                title: cmdConfig.title,
                icon: nil
            ) { [weak self] _ in
                // main mode: 调用插件的 handleCommand
                if let plugin = self?.mainModePlugins[pluginId] {
                    plugin.handleCommand(cmdConfig.id)
                } else {
                    // isolated mode: 通过 ExtensionHost 发送命令
                    Task {
                        try? await ExtensionHostManager.shared.sendRequest(
                            pluginId: pluginId,
                            requestId: "handleCommand",
                            params: ["commandId": cmdConfig.id]
                        )
                    }
                }
            }
            CommandRegistry.shared.register(command)

            // 如果有快捷键，注册到 KeyboardService
            if let keyBindingStr = cmdConfig.keyBinding {
                guard let keyStroke = parseKeyBinding(keyBindingStr) else {
                    logWarn("[SDKPluginLoader] Failed to parse keyBinding '\(keyBindingStr)' for \(cmdConfig.id)")
                    continue
                }
                KeyboardServiceImpl.shared.bind(keyStroke, to: cmdConfig.id, when: nil)
            }
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
                // 先检查 main mode 插件
                if let mainPlugin = self?.mainModePlugins[pluginId] {
                    return mainPlugin.infoPanelView(for: content.id) ?? AnyView(
                        Text("InfoPanel view not provided")
                            .foregroundColor(.secondary)
                    )
                }
                // 再检查 isolated mode 插件
                if let provider = self?.viewProviders[pluginId] {
                    return provider.createInfoPanelView(id: content.id) ?? AnyView(
                        Text("InfoPanel view not provided")
                            .foregroundColor(.secondary)
                    )
                }
                return AnyView(
                    Text("Plugin not loaded")
                        .foregroundColor(.secondary)
                )
            }
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
        }
    }

    /// 显示插件的 bottomDock
    func showBottomDock(pluginId: String) {
        guard let config = SDKPluginLoader.bottomDockConfigs[pluginId],
              let provider = viewProviders[pluginId],
              let view = provider.createBottomDockView(id: config.id) else {
            logWarn("[SDKPluginLoader] Cannot show bottomDock for \(pluginId): config or view not available")
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

    /// 获取 main mode 插件实例
    func getMainModePlugin(_ pluginId: String) -> (any ETermKit.Plugin)? {
        return mainModePlugins[pluginId]
    }

    /// 获取 bubble 内容视图
    func getBubbleContentView(pluginId: String, bubbleId: String) -> AnyView? {
        guard let provider = viewProviders[pluginId] else { return nil }
        return provider.createBubbleContentView(id: bubbleId)
    }

    // MARK: - Slot Registration

    /// 已注册的 tabSlots 配置 (pluginId -> [TabSlot])
    private static var tabSlotsConfigs: [String: [PluginManifest.TabSlot]] = [:]

    /// 已注册的 pageSlots 配置 (pluginId -> [PageSlot])
    private static var pageSlotsConfigs: [String: [PluginManifest.PageSlot]] = [:]

    /// 注册 SDK 插件的 tabSlots
    private func registerTabSlots(for manifest: PluginManifest) {
        guard !manifest.tabSlots.isEmpty else { return }

        let pluginId = manifest.id

        for slotConfig in manifest.tabSlots {
            tabSlotRegistry.register(
                pluginId: pluginId,
                slotId: slotConfig.id,
                priority: 0
            ) { [weak self] tab in
                // Tab 已遵循 TabSlotContext 协议
                self?.getTabSlotView(pluginId: pluginId, slotId: slotConfig.id, tab: tab)
            }
        }

        // 存储配置（供查询使用）
        SDKPluginLoader.tabSlotsConfigs[pluginId] = manifest.tabSlots
    }

    /// 注册 SDK 插件的 pageSlots
    private func registerPageSlots(for manifest: PluginManifest) {
        guard !manifest.pageSlots.isEmpty else { return }

        let pluginId = manifest.id

        for slotConfig in manifest.pageSlots {
            pageSlotRegistry.register(
                pluginId: pluginId,
                slotId: slotConfig.id,
                priority: 0
            ) { [weak self] page in
                // Page 已遵循 PageSlotContext 协议
                self?.getPageSlotView(pluginId: pluginId, slotId: slotConfig.id, page: page)
            }
        }

        // 存储配置（供查询使用）
        SDKPluginLoader.pageSlotsConfigs[pluginId] = manifest.pageSlots
    }

    /// 获取所有已注册的 tabSlots 配置
    static func getAllTabSlotConfigs() -> [String: [PluginManifest.TabSlot]] {
        return tabSlotsConfigs
    }

    /// 获取所有已注册的 pageSlots 配置
    static func getAllPageSlotConfigs() -> [String: [PluginManifest.PageSlot]] {
        return pageSlotsConfigs
    }

    /// 获取 Tab Slot 视图
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID
    ///   - tab: Tab 上下文
    /// - Returns: Slot 视图
    func getTabSlotView(pluginId: String, slotId: String, tab: any TabSlotContext) -> AnyView? {
        guard let manifest = manifests[pluginId] else { return nil }

        if manifest.runMode == .main {
            return mainModePlugins[pluginId]?.tabSlotView(for: slotId, tab: tab)
        } else {
            // isolated mode 暂不支持 Slot（需要 IPC 传递 Context）
            return nil
        }
    }

    /// 获取 Page Slot 视图
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID
    ///   - page: Page 上下文
    /// - Returns: Slot 视图
    func getPageSlotView(pluginId: String, slotId: String, page: any PageSlotContext) -> AnyView? {
        guard let manifest = manifests[pluginId] else { return nil }

        if manifest.runMode == .main {
            return mainModePlugins[pluginId]?.pageSlotView(for: slotId, page: page)
        } else {
            // isolated mode 暂不支持 Slot（需要 IPC 传递 Context）
            return nil
        }
    }

    // MARK: - PageBar Registration

    /// 注册 SDK 插件的 pageBarItems 到 PageBarItemRegistry
    private func registerPageBarItems(for manifest: PluginManifest) {
        guard !manifest.pageBarItems.isEmpty else { return }

        let pluginId = manifest.id
        let isMainMode = manifest.runMode == .main

        for itemConfig in manifest.pageBarItems {
            PageBarItemRegistry.shared.registerItem(
                for: pluginId,
                id: itemConfig.id
            ) { [weak self] in
                self?.getPageBarView(pluginId: pluginId, itemId: itemConfig.id, isMainMode: isMainMode)
                    ?? AnyView(Text("PageBar view not available").font(.caption))
            }
        }
    }

    /// 获取 PageBar 视图（区分 main/isolated 模式）
    private func getPageBarView(pluginId: String, itemId: String, isMainMode: Bool) -> AnyView? {
        if isMainMode {
            // main mode: 使用 Plugin.pageBarView(for:)
            return mainModePlugins[pluginId]?.pageBarView(for: itemId)
        } else {
            // isolated mode: 使用 ViewProvider（暂不支持）
            return nil
        }
    }

    // MARK: - Bottom Overlay

    /// 获取底部 Overlay 视图
    ///
    /// 遍历所有 main mode 插件，返回提供该 overlay 的视图
    func getWindowBottomOverlayView(for id: String) -> AnyView? {
        for (_, plugin) in mainModePlugins {
            if let view = plugin.windowBottomOverlayView(for: id) {
                return view
            }
        }
        return nil
    }
}
