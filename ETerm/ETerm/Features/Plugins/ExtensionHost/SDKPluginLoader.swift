//
//  SDKPluginLoader.swift
//  ETerm
//
//  SDK 插件加载器
//  负责加载使用 ETermKit SDK 开发的插件

import Foundation
import SwiftUI
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
final class SDKPluginLoader {

    static let shared = SDKPluginLoader()

    // MARK: - Properties

    /// 已加载的插件 Manifest
    private var manifests: [String: PluginManifest] = [:]

    /// 插件 Bundle 路径 (pluginId -> bundlePath)
    private var bundlePaths: [String: String] = [:]

    /// 已加载的 View Bundle
    private var viewBundles: [String: Bundle] = [:]

    /// 加载失败的插件
    private var failedPlugins: [String: PluginError] = [:]

    /// 跳过的插件（依赖问题）
    private var skippedPlugins: [String: String] = [:]

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// 加载所有 SDK 插件
    func loadAllPlugins() async {
        // 1. 启动 Extension Host
        do {
            try await ExtensionHostManager.shared.start()
        } catch {
            print("[SDKPluginLoader] Failed to start Extension Host: \(error)")
            return
        }

        // 2. 扫描插件目录
        let pluginPaths = scanPluginDirectories()

        // 3. 读取所有 Manifest
        var pendingManifests: [PluginManifest] = []
        for path in pluginPaths {
            if let manifest = loadManifest(from: path) {
                pendingManifests.append(manifest)
            }
        }

        // 4. 拓扑排序
        let sortedManifests = topologicalSort(pendingManifests)

        // 5. 按顺序加载
        for manifest in sortedManifests {
            await loadPlugin(manifest)
        }

        print("[SDKPluginLoader] Loaded \(manifests.count) plugins, \(failedPlugins.count) failed, \(skippedPlugins.count) skipped")
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

    /// 获取插件 View Bundle
    func getViewBundle(_ pluginId: String) -> Bundle? {
        return viewBundles[pluginId]
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

        // 注册 Manifest
        manifests[pluginId] = manifest

        // 注册能力
        await ExtensionHostManager.shared.getBridge()?.registerManifest(manifest)

        // 激活插件（通知 Extension Host）
        guard let bundlePath = bundlePaths[pluginId] else {
            print("[SDKPluginLoader] Missing bundlePath for \(pluginId)")
            failedPlugins[pluginId] = .activationFailed(reason: "Missing bundlePath")
            manifests.removeValue(forKey: pluginId)
            return
        }

        do {
            try await ExtensionHostManager.shared.getBridge()?.activatePlugin(
                pluginId: pluginId,
                bundlePath: bundlePath,
                manifest: manifest
            )
            print("[SDKPluginLoader] Activated plugin: \(pluginId)")

            // 注册 sidebarTabs 到 SidebarRegistry
            registerSidebarTabs(for: manifest)

            // 注册 keyBindings 到 KeyboardService
            registerKeyBindings(for: manifest)
        } catch {
            print("[SDKPluginLoader] Failed to activate \(pluginId): \(error)")
            failedPlugins[pluginId] = .activationFailed(reason: error.localizedDescription)
            manifests.removeValue(forKey: pluginId)
        }
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

        for tabConfig in manifest.sidebarTabs {
            let tab = SidebarTab(
                id: tabConfig.id,
                title: tabConfig.title,
                icon: tabConfig.icon
            ) {
                // SDK 插件使用通用的 ViewModel 驱动视图
                AnyView(SDKPluginSidebarView(
                    pluginId: manifest.id,
                    tabId: tabConfig.id,
                    title: tabConfig.title
                ))
            }

            SidebarRegistry.shared.registerTab(
                for: manifest.id,
                pluginName: manifest.name,
                tab: tab
            )

            print("[SDKPluginLoader] Registered sidebar tab '\(tabConfig.id)' for \(manifest.id)")
        }
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
}
