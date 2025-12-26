//
//  ImmediateExecutor.swift
//  ETerm
//
//  立即执行器 - 使用 Process API 后台执行命令

import Foundation

/// 立即执行器
///
/// 使用系统 Process API 轻量级执行命令，适合：
/// - 快速查询命令（git status, ls, pwd 等）
/// - 一次性操作（open ., mkdir 等）
/// - 不需要交互的命令
final class ImmediateExecutor {

    /// 执行命令
    /// - Parameters:
    ///   - command: 要执行的命令字符串
    ///   - cwd: 工作目录
    ///   - completion: 完成回调（在后台线程调用）
    static func execute(
        _ command: String,
        cwd: String,
        completion: @escaping (CommandExecutionResult) -> Void
    ) {
        // 在后台线程执行
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try executeSync(command, cwd: cwd)
                completion(.success(result))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    // MARK: - 私有方法

    /// 同步执行命令
    private static func executeSync(_ command: String, cwd: String) throws -> String {
        let process = Process()

        // 配置 shell 环境
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // 继承环境变量
        process.environment = ProcessInfo.processInfo.environment

        // 捕获输出
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // 执行
        try process.run()
        process.waitUntilExit()

        // 读取输出
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        // 检查退出状态
        if process.terminationStatus == 0 {
            // 成功：返回输出（优先返回 stdout，如果为空则返回提示）
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return formatOutput(output)
            } else if !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 某些命令会将正常输出写到 stderr（如 git）
                return formatOutput(error)
            } else {
                return "✓ 命令执行成功（无输出）"
            }
        } else {
            // 失败：返回错误信息
            let errorMessage = !error.isEmpty ? error : output
            throw ExecutionError.commandFailed(
                exitCode: process.terminationStatus,
                message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// 格式化输出（截断过长的输出）
    private static func formatOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)

        // 最多显示前 5 行
        if lines.count > 5 {
            let preview = lines.prefix(5).joined(separator: "\n")
            return "\(preview)\n... (\(lines.count - 5) 行已省略)"
        }

        // 最多显示 200 个字符
        if trimmed.count > 200 {
            let preview = String(trimmed.prefix(200))
            return "\(preview)... (\(trimmed.count - 200) 字符已省略)"
        }

        return trimmed
    }
}

// MARK: - 错误定义

/// 执行错误
enum ExecutionError: LocalizedError {
    case commandFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let message):
            if message.isEmpty {
                return "命令执行失败 (退出码: \(code))"
            } else {
                return "命令执行失败 (退出码: \(code)):\n\(message)"
            }
        }
    }
}
