// DevHelperLogic.swift
// DevHelperKit
//
// 开发助手插件逻辑 - 在 Extension Host 进程中运行

import Foundation
import ETermKit

/// 开发助手插件逻辑入口
///
/// 线程安全说明：
/// - 使用串行队列 `stateQueue` 保护所有可变状态访问
/// - `host` 引用的 `HostBridge` 本身是 `Sendable` 且内部线程安全
@objc(DevHelperLogic)
public final class DevHelperLogic: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "com.eterm.dev-helper" }

    /// 串行队列，保护可变状态访问
    private let stateQueue = DispatchQueue(label: "com.eterm.dev-helper.state")

    /// 受保护的可变状态
    private var _host: HostBridge?
    private var _projects: [DetectedProject] = []
    private var _workspaceFolders: [String] = []

    /// 线程安全的 host 访问
    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    /// 线程安全的 projects 访问
    private var projects: [DetectedProject] {
        get { stateQueue.sync { _projects } }
        set { stateQueue.sync { _projects = newValue } }
    }

    /// 线程安全的 workspaceFolders 访问
    private var workspaceFolders: [String] {
        get { stateQueue.sync { _workspaceFolders } }
        set { stateQueue.sync { _workspaceFolders = newValue } }
    }

    public required override init() {
        super.init()
        print("[DevHelperLogic] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[DevHelperLogic] Activated")

        // 从 Workspace 插件获取文件夹列表
        loadWorkspaceFolders()

        // 扫描项目
        scanProjects()
    }

    public func deactivate() {
        print("[DevHelperLogic] Deactivating...")
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[DevHelperLogic] Event: \(eventName)")

        switch eventName {
        case "plugin.workspace.folderAdded", "plugin.workspace.folderRemoved":
            // 工作区文件夹变化，重新扫描
            loadWorkspaceFolders()
            scanProjects()
        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        print("[DevHelperLogic] Command: \(commandId)")

        switch commandId {
        case "devHelper.refresh":
            loadWorkspaceFolders()
            scanProjects()
        default:
            break
        }
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[DevHelperLogic] Request: \(requestId) params: \(params)")

        switch requestId {
        case "getProjects":
            return getProjectsResponse()

        case "getProjectTree":
            return getProjectTreeResponse()

        case "getRunningTasks":
            return getRunningTasksResponse()

        case "startTask":
            guard let projectPath = params["projectPath"] as? String,
                  let scriptName = params["scriptName"] as? String else {
                return ["success": false, "error": "Missing projectPath or scriptName"]
            }
            return startTask(projectPath: projectPath, scriptName: scriptName, terminalId: params["terminalId"] as? Int ?? -1)

        case "stopTask":
            guard let projectPath = params["projectPath"] as? String,
                  let scriptName = params["scriptName"] as? String else {
                return ["success": false, "error": "Missing projectPath or scriptName"]
            }
            return stopTask(projectPath: projectPath, scriptName: scriptName)

        case "isTaskRunning":
            guard let projectPath = params["projectPath"] as? String,
                  let scriptName = params["scriptName"] as? String else {
                return ["success": false, "error": "Missing projectPath or scriptName"]
            }
            let isRunning = RunningTaskManager.shared.isRunning(projectPath: projectPath, scriptName: scriptName)
            return ["success": true, "isRunning": isRunning]

        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - Workspace Integration

    private func loadWorkspaceFolders() {
        guard let host = host else { return }

        // 调用 Workspace 插件的服务获取文件夹列表
        if let result = host.callService(pluginId: "com.eterm.workspace", name: "getFolders", params: [:]),
           let folders = result["folders"] as? [[String: Any]] {
            workspaceFolders = folders.compactMap { $0["path"] as? String }
            print("[DevHelperLogic] Loaded \(workspaceFolders.count) workspace folders")
        }
    }

    // MARK: - Project Scanning

    private func scanProjects() {
        let folders = workspaceFolders

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folderURLs = folders.map { URL(fileURLWithPath: $0) }
            let scannedProjects = ProjectScanner.shared.scan(folders: folderURLs)

            DispatchQueue.main.async {
                self?.projects = scannedProjects
                self?.updateUI()

                // 发送事件通知
                self?.host?.emit(eventName: "plugin.devHelper.projectScanned", payload: [
                    "count": scannedProjects.count
                ])
            }
        }
    }

    // MARK: - Response Builders

    private func getProjectsResponse() -> [String: Any] {
        let projectList = projects.map { project -> [String: Any] in
            [
                "id": project.id.uuidString,
                "name": project.name,
                "path": project.path,
                "type": project.type,
                "scripts": project.scripts.map { script -> [String: Any] in
                    [
                        "id": script.id.uuidString,
                        "name": script.name,
                        "command": script.command,
                        "displayName": script.displayName as Any
                    ]
                }
            ]
        }
        return ["success": true, "projects": projectList]
    }

    private func getProjectTreeResponse() -> [String: Any] {
        let currentProjects = projects
        guard !currentProjects.isEmpty else {
            return ["success": true, "tree": [], "commonPrefix": ""]
        }

        // 将路径分解为组件
        let pathComponents = currentProjects.map { project -> ([String], DetectedProject) in
            let components = (project.path as NSString).pathComponents.filter { $0 != "/" }
            return (components, project)
        }

        // 找到公共前缀
        let allComponents = pathComponents.map { $0.0 }
        let commonPrefix = findCommonPrefix(allComponents)
        let commonPrefixPath = commonPrefix.isEmpty ? "" : "/" + commonPrefix.joined(separator: "/")

        // 构建树
        let tree = buildTree(
            items: pathComponents,
            prefixLength: commonPrefix.count,
            basePath: commonPrefixPath
        )

        return [
            "success": true,
            "tree": tree,
            "commonPrefix": commonPrefixPath
        ]
    }

    private func getRunningTasksResponse() -> [String: Any] {
        let tasks = RunningTaskManager.shared.getAllTasks()
        let taskList = tasks.map { task -> [String: Any] in
            [
                "id": task.id,
                "projectPath": task.projectPath,
                "projectName": task.projectName,
                "scriptName": task.scriptName,
                "command": task.command,
                "terminalId": task.terminalId
            ]
        }
        return ["success": true, "tasks": taskList]
    }

    // MARK: - Task Management

    private func startTask(projectPath: String, scriptName: String, terminalId: Int) -> [String: Any] {
        // 查找项目和脚本
        guard let project = projects.first(where: { $0.path == projectPath }),
              let script = project.scripts.first(where: { $0.name == scriptName }) else {
            return ["success": false, "error": "Project or script not found"]
        }

        // 注册任务
        RunningTaskManager.shared.registerTask(
            projectPath: projectPath,
            projectName: project.name,
            scriptName: scriptName,
            command: script.command,
            terminalId: terminalId
        )

        // 发送事件
        host?.emit(eventName: "plugin.devHelper.taskStarted", payload: [
            "projectPath": projectPath,
            "scriptName": scriptName,
            "terminalId": terminalId
        ])

        updateUI()

        return ["success": true, "command": script.command]
    }

    private func stopTask(projectPath: String, scriptName: String) -> [String: Any] {
        RunningTaskManager.shared.removeTask(projectPath: projectPath, scriptName: scriptName)

        // 发送事件
        host?.emit(eventName: "plugin.devHelper.taskStopped", payload: [
            "projectPath": projectPath,
            "scriptName": scriptName
        ])

        updateUI()

        return ["success": true]
    }

    // MARK: - Tree Building

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

    private func buildTree(
        items: [([String], DetectedProject)],
        prefixLength: Int,
        basePath: String
    ) -> [[String: Any]] {
        var groups: [String: [([String], DetectedProject)]] = [:]

        for item in items {
            guard prefixLength < item.0.count else { continue }
            let nextComponent = item.0[prefixLength]
            groups[nextComponent, default: []].append(item)
        }

        var nodes: [[String: Any]] = []

        for (component, groupItems) in groups.sorted(by: { $0.key < $1.key }) {
            let nodePath = basePath.isEmpty ? "/\(component)" : "\(basePath)/\(component)"

            if groupItems.count == 1 && groupItems[0].0.count == prefixLength + 1 {
                let project = groupItems[0].1
                nodes.append([
                    "name": component,
                    "fullPath": nodePath,
                    "isLeaf": true,
                    "project": projectToDict(project),
                    "children": []
                ])
            } else {
                let exactMatch = groupItems.first { $0.0.count == prefixLength + 1 }

                let children = buildTree(
                    items: groupItems.filter { $0.0.count > prefixLength + 1 },
                    prefixLength: prefixLength + 1,
                    basePath: nodePath
                )

                var node: [String: Any] = [
                    "name": component,
                    "fullPath": nodePath,
                    "isLeaf": exactMatch != nil,
                    "children": children
                ]

                if let match = exactMatch {
                    node["project"] = projectToDict(match.1)
                }

                nodes.append(node)
            }
        }

        return nodes
    }

    private func projectToDict(_ project: DetectedProject) -> [String: Any] {
        [
            "id": project.id.uuidString,
            "name": project.name,
            "path": project.path,
            "type": project.type,
            "scripts": project.scripts.map { script -> [String: Any] in
                [
                    "id": script.id.uuidString,
                    "name": script.name,
                    "command": script.command,
                    "displayName": script.displayName as Any
                ]
            }
        ]
    }

    // MARK: - UI Update

    private func updateUI() {
        let currentProjects = projects
        let runningTasks = RunningTaskManager.shared.getAllTasks()

        // 构建项目树
        let treeResponse = getProjectTreeResponse()
        let tree = treeResponse["tree"] as? [[String: Any]] ?? []
        let commonPrefix = treeResponse["commonPrefix"] as? String ?? ""

        host?.updateViewModel(Self.id, data: [
            "projectCount": currentProjects.count,
            "projects": currentProjects.map { projectToDict($0) },
            "tree": tree,
            "commonPrefix": commonPrefix,
            "runningTasks": runningTasks.map { task in
                [
                    "id": task.id,
                    "projectPath": task.projectPath,
                    "projectName": task.projectName,
                    "scriptName": task.scriptName,
                    "command": task.command,
                    "terminalId": task.terminalId
                ]
            }
        ])
    }
}
