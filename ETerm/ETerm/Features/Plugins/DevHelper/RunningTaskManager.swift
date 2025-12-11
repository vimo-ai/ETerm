//
//  RunningTaskManager.swift
//  ETerm
//
//  运行中任务管理器

import Foundation
import Combine

/// 运行中的任务
struct RunningTask: Identifiable {
    let id: String              // 唯一标识：projectPath + scriptName
    let projectPath: String
    let projectName: String
    let scriptName: String
    let command: String
    var terminalId: Int

    init(project: DetectedProject, script: ProjectScript, terminalId: Int) {
        self.id = "\(project.path.path):\(script.name)"
        self.projectPath = project.path.path
        self.projectName = project.name
        self.scriptName = script.name
        self.command = script.command
        self.terminalId = terminalId
    }
}

/// 运行中任务管理器
final class RunningTaskManager: ObservableObject {
    static let shared = RunningTaskManager()

    /// 运行中的任务：taskId -> RunningTask
    @Published private(set) var tasks: [String: RunningTask] = [:]

    private init() {}

    // MARK: - 查询

    /// 检查脚本是否正在运行
    func isRunning(project: DetectedProject, script: ProjectScript) -> Bool {
        let taskId = makeTaskId(project: project, script: script)
        return tasks[taskId] != nil
    }

    /// 获取运行中的任务
    func getTask(project: DetectedProject, script: ProjectScript) -> RunningTask? {
        let taskId = makeTaskId(project: project, script: script)
        return tasks[taskId]
    }

    /// 获取任务的终端 ID
    func getTerminalId(project: DetectedProject, script: ProjectScript) -> Int? {
        return getTask(project: project, script: script)?.terminalId
    }

    // MARK: - 管理

    /// 注册运行中的任务
    func registerTask(project: DetectedProject, script: ProjectScript, terminalId: Int) {
        let task = RunningTask(project: project, script: script, terminalId: terminalId)
        tasks[task.id] = task
        print("📦 [TaskManager] 注册任务: \(task.scriptName) @ \(task.projectName), terminalId=\(terminalId)")
    }

    /// 移除任务（终端关闭时调用）
    func removeTask(project: DetectedProject, script: ProjectScript) {
        let taskId = makeTaskId(project: project, script: script)
        if let task = tasks.removeValue(forKey: taskId) {
            print("📦 [TaskManager] 移除任务: \(task.scriptName) @ \(task.projectName)")
        }
    }

    /// 根据终端 ID 移除任务
    func removeTask(byTerminalId terminalId: Int) {
        if let taskId = tasks.first(where: { $0.value.terminalId == terminalId })?.key {
            if let task = tasks.removeValue(forKey: taskId) {
                print("📦 [TaskManager] 移除任务: \(task.scriptName) @ \(task.projectName)")
            }
        }
    }

    // MARK: - 私有方法

    private func makeTaskId(project: DetectedProject, script: ProjectScript) -> String {
        return "\(project.path.path):\(script.name)"
    }
}
