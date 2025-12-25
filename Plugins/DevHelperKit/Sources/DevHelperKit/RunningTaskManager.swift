// RunningTaskManager.swift
// DevHelperKit
//
// 运行中任务管理器

import Foundation

/// 运行中的任务
public struct RunningTask: Identifiable, Codable, Sendable {
    public let id: String              // 唯一标识：projectPath + scriptName
    public let projectPath: String
    public let projectName: String
    public let scriptName: String
    public let command: String
    public var terminalId: Int

    public init(project: DetectedProject, script: ProjectScript, terminalId: Int) {
        self.id = "\(project.path):\(script.name)"
        self.projectPath = project.path
        self.projectName = project.name
        self.scriptName = script.name
        self.command = script.command
        self.terminalId = terminalId
    }

    public init(id: String, projectPath: String, projectName: String, scriptName: String, command: String, terminalId: Int) {
        self.id = id
        self.projectPath = projectPath
        self.projectName = projectName
        self.scriptName = scriptName
        self.command = command
        self.terminalId = terminalId
    }
}

/// 运行中任务管理器
///
/// 线程安全说明：
/// - 使用串行队列 `stateQueue` 保护所有可变状态访问
public final class RunningTaskManager: @unchecked Sendable {
    public static let shared = RunningTaskManager()

    /// 串行队列，保护可变状态访问
    private let stateQueue = DispatchQueue(label: "com.eterm.dev-helper.tasks")

    /// 运行中的任务：taskId -> RunningTask
    private var _tasks: [String: RunningTask] = [:]

    /// 线程安全的 tasks 访问
    public var tasks: [String: RunningTask] {
        get { stateQueue.sync { _tasks } }
    }

    private init() {}

    // MARK: - 查询

    /// 检查脚本是否正在运行
    public func isRunning(project: DetectedProject, script: ProjectScript) -> Bool {
        let taskId = makeTaskId(project: project, script: script)
        return stateQueue.sync { _tasks[taskId] != nil }
    }

    /// 检查脚本是否正在运行（使用路径和脚本名）
    public func isRunning(projectPath: String, scriptName: String) -> Bool {
        let taskId = "\(projectPath):\(scriptName)"
        return stateQueue.sync { _tasks[taskId] != nil }
    }

    /// 获取运行中的任务
    public func getTask(project: DetectedProject, script: ProjectScript) -> RunningTask? {
        let taskId = makeTaskId(project: project, script: script)
        return stateQueue.sync { _tasks[taskId] }
    }

    /// 获取任务的终端 ID
    public func getTerminalId(project: DetectedProject, script: ProjectScript) -> Int? {
        return getTask(project: project, script: script)?.terminalId
    }

    /// 获取所有运行中的任务
    public func getAllTasks() -> [RunningTask] {
        return stateQueue.sync { Array(_tasks.values) }
    }

    // MARK: - 管理

    /// 注册运行中的任务
    public func registerTask(project: DetectedProject, script: ProjectScript, terminalId: Int) {
        let task = RunningTask(project: project, script: script, terminalId: terminalId)
        stateQueue.sync {
            _tasks[task.id] = task
        }
    }

    /// 注册运行中的任务（使用详细参数）
    public func registerTask(projectPath: String, projectName: String, scriptName: String, command: String, terminalId: Int) {
        let taskId = "\(projectPath):\(scriptName)"
        let task = RunningTask(
            id: taskId,
            projectPath: projectPath,
            projectName: projectName,
            scriptName: scriptName,
            command: command,
            terminalId: terminalId
        )
        stateQueue.sync {
            _tasks[taskId] = task
        }
    }

    /// 移除任务（终端关闭时调用）
    public func removeTask(project: DetectedProject, script: ProjectScript) {
        let taskId = makeTaskId(project: project, script: script)
        stateQueue.sync {
            _ = _tasks.removeValue(forKey: taskId)
        }
    }

    /// 移除任务（使用路径和脚本名）
    public func removeTask(projectPath: String, scriptName: String) {
        let taskId = "\(projectPath):\(scriptName)"
        stateQueue.sync {
            _ = _tasks.removeValue(forKey: taskId)
        }
    }

    /// 根据终端 ID 移除任务
    public func removeTask(byTerminalId terminalId: Int) {
        stateQueue.sync {
            if let taskId = _tasks.first(where: { $0.value.terminalId == terminalId })?.key {
                _ = _tasks.removeValue(forKey: taskId)
            }
        }
    }

    // MARK: - 私有方法

    private func makeTaskId(project: DetectedProject, script: ProjectScript) -> String {
        return "\(project.path):\(script.name)"
    }
}
