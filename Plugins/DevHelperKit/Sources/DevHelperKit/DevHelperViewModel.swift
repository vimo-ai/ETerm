// DevHelperViewModel.swift
// DevHelperKit
//
// 开发助手 ViewModel - 在主进程中运行

import Foundation
import Combine
import ETermKit

/// 选中的脚本
public struct SelectedScript: Equatable, Sendable {
    public let projectId: UUID
    public let projectName: String
    public let projectPath: String
    public let scriptId: UUID
    public let scriptName: String
    public let scriptCommand: String

    public init(project: DetectedProject, script: ProjectScript) {
        self.projectId = project.id
        self.projectName = project.name
        self.projectPath = project.path
        self.scriptId = script.id
        self.scriptName = script.name
        self.scriptCommand = script.command
    }

    public static func == (lhs: SelectedScript, rhs: SelectedScript) -> Bool {
        lhs.projectId == rhs.projectId && lhs.scriptId == rhs.scriptId
    }
}

/// 项目树节点
public final class ProjectTreeNode: Identifiable, ObservableObject {
    public let id = UUID()
    public let name: String
    public let fullPath: String
    public let project: DetectedProject?
    @Published public var children: [ProjectTreeNode]
    @Published public var isExpanded: Bool = true

    public var isLeaf: Bool { project != nil }

    public init(name: String, fullPath: String, project: DetectedProject? = nil, children: [ProjectTreeNode] = []) {
        self.name = name
        self.fullPath = fullPath
        self.project = project
        self.children = children
    }
}

/// 开发助手 ViewModel
public final class DevHelperViewModel: ObservableObject, PluginViewModel {
    @Published public var projects: [DetectedProject] = []
    @Published public var rootNodes: [ProjectTreeNode] = []
    @Published public var runningTasks: [RunningTask] = []
    @Published public var isScanning: Bool = false
    @Published public var commonPrefix: String = ""

    public required init() {}

    public func update(from data: [String: Any]) {
        if let projectsData = data["projects"] as? [[String: Any]] {
            projects = projectsData.compactMap { parseProject($0) }
        }

        if let treeData = data["tree"] as? [[String: Any]] {
            rootNodes = treeData.compactMap { parseTreeNode($0) }
        }

        if let prefix = data["commonPrefix"] as? String {
            commonPrefix = prefix
        }

        if let tasksData = data["runningTasks"] as? [[String: Any]] {
            runningTasks = tasksData.compactMap { parseRunningTask($0) }
        }
    }

    // MARK: - 任务状态查询

    public func isRunning(projectPath: String, scriptName: String) -> Bool {
        let taskId = "\(projectPath):\(scriptName)"
        return runningTasks.contains { $0.id == taskId }
    }

    public func getTerminalId(projectPath: String, scriptName: String) -> Int? {
        let taskId = "\(projectPath):\(scriptName)"
        return runningTasks.first { $0.id == taskId }?.terminalId
    }

    // MARK: - 解析辅助方法

    private func parseProject(_ data: [String: Any]) -> DetectedProject? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let path = data["path"] as? String,
              let type = data["type"] as? String else {
            return nil
        }

        var scripts: [ProjectScript] = []
        if let scriptsData = data["scripts"] as? [[String: Any]] {
            scripts = scriptsData.compactMap { parseScript($0) }
        }

        return DetectedProject(id: id, name: name, path: path, type: type, scripts: scripts)
    }

    private func parseScript(_ data: [String: Any]) -> ProjectScript? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let command = data["command"] as? String else {
            return nil
        }

        let displayName = data["displayName"] as? String

        return ProjectScript(id: id, name: name, command: command, displayName: displayName)
    }

    private func parseTreeNode(_ data: [String: Any]) -> ProjectTreeNode? {
        guard let name = data["name"] as? String,
              let fullPath = data["fullPath"] as? String else {
            return nil
        }

        var project: DetectedProject?
        if let projectData = data["project"] as? [String: Any] {
            project = parseProject(projectData)
        }

        var children: [ProjectTreeNode] = []
        if let childrenData = data["children"] as? [[String: Any]] {
            children = childrenData.compactMap { parseTreeNode($0) }
        }

        return ProjectTreeNode(name: name, fullPath: fullPath, project: project, children: children)
    }

    private func parseRunningTask(_ data: [String: Any]) -> RunningTask? {
        guard let id = data["id"] as? String,
              let projectPath = data["projectPath"] as? String,
              let projectName = data["projectName"] as? String,
              let scriptName = data["scriptName"] as? String,
              let command = data["command"] as? String,
              let terminalId = data["terminalId"] as? Int else {
            return nil
        }

        return RunningTask(
            id: id,
            projectPath: projectPath,
            projectName: projectName,
            scriptName: scriptName,
            command: command,
            terminalId: terminalId
        )
    }
}
