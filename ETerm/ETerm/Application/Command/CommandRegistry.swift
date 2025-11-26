//
//  CommandRegistry.swift
//  ETerm
//
//  应用层 - 命令注册表实现

import Foundation

/// 命令注册表 - 管理所有已注册的命令
///
/// 单例模式，确保全局只有一个命令注册中心
final class CommandRegistry: CommandService {
    static let shared = CommandRegistry()

    // MARK: - 私有属性

    /// 命令存储：CommandID -> Command
    private var commands: [CommandID: Command] = [:]

    /// 线程安全队列
    private let queue = DispatchQueue(label: "com.eterm.command-registry", attributes: .concurrent)

    // MARK: - 初始化

    private init() {}

    // MARK: - CommandService 实现

    func register(_ command: Command) {
        queue.async(flags: .barrier) {
            self.commands[command.id] = command
        }
    }

    func unregister(_ id: CommandID) {
        queue.async(flags: .barrier) {
            self.commands.removeValue(forKey: id)
        }
    }

    func execute(_ id: CommandID, context: CommandContext) {
        var command: Command?
        queue.sync {
            command = commands[id]
        }

        guard let command = command else {
            print("⚠️ 命令不存在: \(id)")
            return
        }

        // 在主线程执行命令（UI 操作需要在主线程）
        DispatchQueue.main.async {
            command.handler(context)
        }
    }

    func exists(_ id: CommandID) -> Bool {
        queue.sync {
            commands[id] != nil
        }
    }

    func allCommands() -> [Command] {
        queue.sync {
            Array(commands.values)
        }
    }
}
