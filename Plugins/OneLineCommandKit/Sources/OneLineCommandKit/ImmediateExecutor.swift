//
//  ImmediateExecutor.swift
//  OneLineCommandKit
//
//  立即执行器 - 使用 Process API 后台执行命令

import Foundation

/// 命令执行结果
public enum CommandExecutionResult {
    case success(String)  // 成功，包含输出
    case failure(String)  // 失败，包含错误信息
}

/// 立即执行器
///
/// 使用系统 Process API 轻量级执行命令，适合：
/// - 快速查询命令（git status, ls, pwd 等）
/// - 一次性操作（open ., mkdir 等）
/// - 不需要交互的命令
public final class ImmediateExecutor {

    /// 执行命令（异步）
    /// - Parameters:
    ///   - command: 要执行的命令字符串
    ///   - cwd: 工作目录
    ///   - completion: 完成回调（在后台线程调用）
    public static func execute(
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

    // MARK: - Internal Methods

    /// 同步执行命令（带超时）
    /// - Parameters:
    ///   - command: 要执行的命令
    ///   - cwd: 工作目录
    ///   - timeout: 超时时间（秒），默认 30 秒
    static func executeSync(_ command: String, cwd: String, timeout: TimeInterval = 30) throws -> String {
        let process = Process()

        // 配置 shell 环境
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // 继承环境变量
        process.environment = ProcessInfo.processInfo.environment

        // 捕获输出（使用异步读取避免死锁）
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var outputData = Data()
        var errorData = Data()
        let outputLock = NSLock()
        let errorLock = NSLock()

        // 异步读取 stdout
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputLock.lock()
                outputData.append(data)
                outputLock.unlock()
            }
        }

        // 异步读取 stderr
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorLock.lock()
                errorData.append(data)
                errorLock.unlock()
            }
        }

        // 执行
        try process.run()

        // 等待完成或超时
        let semaphore = DispatchSemaphore(value: 0)
        var didTimeout = false

        process.terminationHandler = { _ in
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            didTimeout = true
            process.terminate()
            // 给进程一点时间来清理
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                process.interrupt()
            }
        }

        // 清理 readability handlers
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        // 读取剩余数据
        outputLock.lock()
        let finalOutputData = outputData
        outputLock.unlock()

        errorLock.lock()
        let finalErrorData = errorData
        errorLock.unlock()

        if didTimeout {
            throw ExecutionError.timeout
        }

        let output = String(data: finalOutputData, encoding: .utf8) ?? ""
        let error = String(data: finalErrorData, encoding: .utf8) ?? ""

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
public enum ExecutionError: LocalizedError {
    case commandFailed(exitCode: Int32, message: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let message):
            if message.isEmpty {
                return "命令执行失败 (退出码: \(code))"
            } else {
                return "命令执行失败 (退出码: \(code)):\n\(message)"
            }
        case .timeout:
            return "命令执行超时 (30秒)"
        }
    }
}
