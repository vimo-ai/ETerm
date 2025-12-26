// WorkspaceLogic.swift
// WorkspaceKit
//
// 工作区插件逻辑 - 在 Extension Host 进程中运行

import Foundation
import ETermKit
// import SQLite3  // 暂时禁用，可能导致 Extension Host 崩溃

/// 工作区文件夹数据模型
struct WorkspaceFolder: Codable, Sendable {
    let path: String
    let addedAt: Date

    init(path: String, addedAt: Date = Date()) {
        self.path = path
        self.addedAt = addedAt
    }
}

/// 工作区插件逻辑入口
///
/// 线程安全说明：
/// - 使用串行队列 `stateQueue` 保护所有可变状态访问
/// - `host` 引用的 `HostBridge` 本身是 `Sendable` 且内部线程安全
@objc(WorkspaceLogic)
public final class WorkspaceLogic: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "com.eterm.workspace" }

    /// 串行队列，保护可变状态访问
    private let stateQueue = DispatchQueue(label: "com.eterm.workspace.state")

    /// 受保护的可变状态
    private var _host: HostBridge?
    private var _folders: [WorkspaceFolder] = []

    /// 线程安全的 host 访问
    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    /// 线程安全的 folders 访问
    private var folders: [WorkspaceFolder] {
        get { stateQueue.sync { _folders } }
        set { stateQueue.sync { _folders = newValue } }
    }

    /// 数据存储路径
    private var storagePath: String {
        NSHomeDirectory() + "/.eterm/plugins/WorkspaceKit/folders.json"
    }

    public required override init() {
        super.init()
        print("[WorkspaceLogic] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[WorkspaceLogic] Activated")

        // 加载保存的工作区数据
        loadFolders()

        // 发送初始状态到 ViewModel
        updateUI()
    }

    public func deactivate() {
        print("[WorkspaceLogic] Deactivating...")
        // 保存数据
        saveFolders()
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[WorkspaceLogic] Event: \(eventName)")
    }

    public func handleCommand(_ commandId: String) {
        print("[WorkspaceLogic] Command: \(commandId)")

        switch commandId {
        case "workspace.refresh":
            loadFolders()
            updateUI()
        default:
            break
        }
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[WorkspaceLogic] Request: \(requestId) params: \(params)")

        switch requestId {
        case "getFolders":
            // 同时推送 ViewModel 更新，确保 View 能收到数据
            updateUI()
            return getFoldersResponse()

        case "addFolder":
            guard let path = params["path"] as? String else {
                return ["success": false, "error": "Missing path"]
            }
            return addFolder(path)

        case "removeFolder":
            guard let path = params["path"] as? String else {
                return ["success": false, "error": "Missing path"]
            }
            return removeFolder(path)

        case "getPathTree":
            return getPathTreeResponse()

        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - Folder Management

    private func getFoldersResponse() -> [String: Any] {
        let folderList = folders.map { folder -> [String: Any] in
            [
                "path": folder.path,
                "addedAt": ISO8601DateFormatter().string(from: folder.addedAt)
            ]
        }
        return ["success": true, "folders": folderList]
    }

    private func addFolder(_ path: String) -> [String: Any] {
        let normalizedPath = (path as NSString).standardizingPath

        // 检查是否已存在
        if folders.contains(where: { $0.path == normalizedPath }) {
            return ["success": false, "error": "Folder already exists"]
        }

        // 检查路径是否是目录
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ["success": false, "error": "Path is not a valid directory"]
        }

        let folder = WorkspaceFolder(path: normalizedPath)
        folders.append(folder)
        saveFolders()
        updateUI()

        // 发送事件通知其他插件
        host?.emit(eventName: "plugin.workspace.folderAdded", payload: ["path": normalizedPath])

        return ["success": true]
    }

    private func removeFolder(_ path: String) -> [String: Any] {
        guard let index = folders.firstIndex(where: { $0.path == path }) else {
            return ["success": false, "error": "Folder not found"]
        }

        folders.remove(at: index)
        saveFolders()
        updateUI()

        // 发送事件通知其他插件
        host?.emit(eventName: "plugin.workspace.folderRemoved", payload: ["path": path])

        return ["success": true]
    }

    // MARK: - Path Tree

    private func getPathTreeResponse() -> [String: Any] {
        let paths = folders.map { $0.path }

        guard !paths.isEmpty else {
            return ["success": true, "tree": [], "commonPrefix": ""]
        }

        // 将路径分解为组件
        let pathComponents = paths.map { path -> [String] in
            return (path as NSString).pathComponents.filter { $0 != "/" }
        }

        // 找到公共前缀
        let commonPrefix = findCommonPrefix(pathComponents)
        let commonPrefixPath = commonPrefix.isEmpty ? "" : "/" + commonPrefix.joined(separator: "/")

        // 构建树
        let tree = buildTree(
            paths: pathComponents,
            prefixLength: commonPrefix.count,
            basePath: commonPrefixPath
        )

        return [
            "success": true,
            "tree": tree,
            "commonPrefix": commonPrefixPath
        ]
    }

    private func findCommonPrefix(_ paths: [[String]]) -> [String] {
        guard let first = paths.first else { return [] }
        guard paths.count > 1 else { return [] }

        var prefix: [String] = []

        for (index, component) in first.enumerated() {
            let allMatch = paths.allSatisfy { path in
                index < path.count && path[index] == component
            }

            if allMatch {
                prefix.append(component)
            } else {
                break
            }
        }

        return prefix
    }

    private func buildTree(paths: [[String]], prefixLength: Int, basePath: String) -> [[String: Any]] {
        var groups: [String: [[String]]] = [:]

        for path in paths {
            guard prefixLength < path.count else { continue }
            let nextComponent = path[prefixLength]
            groups[nextComponent, default: []].append(path)
        }

        var nodes: [[String: Any]] = []

        for (component, groupPaths) in groups.sorted(by: { $0.key < $1.key }) {
            let nodePath = basePath.isEmpty ? "/\(component)" : "\(basePath)/\(component)"

            if groupPaths.count == 1 && groupPaths[0].count == prefixLength + 1 {
                nodes.append([
                    "name": component,
                    "fullPath": nodePath,
                    "isLeaf": true,
                    "children": []
                ])
            } else {
                let hasExactMatch = groupPaths.contains { $0.count == prefixLength + 1 }

                let children = buildTree(
                    paths: groupPaths.filter { $0.count > prefixLength + 1 },
                    prefixLength: prefixLength + 1,
                    basePath: nodePath
                )

                nodes.append([
                    "name": component,
                    "fullPath": nodePath,
                    "isLeaf": hasExactMatch,
                    "children": children
                ])
            }
        }

        return nodes
    }

    // MARK: - Persistence

    private func loadFolders() {
        let path = storagePath

        // 暂时禁用 SwiftData 迁移（可能导致 Extension Host 崩溃）
        // if !FileManager.default.fileExists(atPath: path) {
        //     migrateFromSwiftData()
        // }

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            folders = []
            return
        }

        do {
            folders = try JSONDecoder().decode([WorkspaceFolder].self, from: data)
            print("[WorkspaceLogic] Loaded \(folders.count) folders")
        } catch {
            print("[WorkspaceLogic] Failed to load folders: \(error)")
            folders = []
        }
    }

    /// 从旧的 SwiftData 数据库迁移数据
    /// 暂时禁用 - SQLite3 可能导致 Extension Host 崩溃
    private func migrateFromSwiftData() {
        print("[WorkspaceLogic] SwiftData migration disabled")
        // TODO: 重新实现，使用进程外方式读取 SQLite
    }

    private func saveFolders() {
        let path = storagePath
        let directory = (path as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(folders)
            try data.write(to: URL(fileURLWithPath: path))
            print("[WorkspaceLogic] Saved \(folders.count) folders")
        } catch {
            print("[WorkspaceLogic] Failed to save folders: \(error)")
        }
    }

    // MARK: - UI Update

    private func updateUI() {
        let folderList = folders.map { folder -> [String: Any] in
            [
                "path": folder.path,
                "addedAt": ISO8601DateFormatter().string(from: folder.addedAt)
            ]
        }

        // 构建路径树
        let treeResponse = getPathTreeResponse()
        let tree = treeResponse["tree"] as? [[String: Any]] ?? []
        let commonPrefix = treeResponse["commonPrefix"] as? String ?? ""

        host?.updateViewModel(Self.id, data: [
            "folderCount": folders.count,
            "folders": folderList,
            "tree": tree,
            "commonPrefix": commonPrefix
        ])
    }
}
