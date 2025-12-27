// main.swift
// ETermExtensionHost
//
// Plugin logic execution process entry point
//
// 改造后的架构：
// - Host 作为 IPC 服务端常驻运行
// - 支持配置生命周期（跟随客户端退出、保持 1h/5h/24h、永久）

import Foundation
import ETermKit

fputs("[ExtensionHost] Starting...\n", stderr)

// MARK: - Entry Point

/// 命令行参数解析结果
struct HostArguments {
    let socketPath: String
    let lifecycle: HostLifecycle
}

/// Parse command line arguments
/// Usage: ETermExtensionHost --socket <path> [--lifecycle <mode>]
///
/// Lifecycle modes:
/// - exitWithClient: 最后一个客户端断开后退出
/// - persist1Hour: 保持 1 小时（默认）
/// - persist5Hours: 保持 5 小时
/// - persist24Hours: 保持 24 小时
/// - persistForever: 永久运行
func parseArguments() -> HostArguments? {
    let args = CommandLine.arguments

    var socketPath: String?
    var lifecycle: HostLifecycle = .persist1Hour  // 默认 1 小时

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--socket":
            if i + 1 < args.count {
                socketPath = args[i + 1]
                i += 1
            }
        case "--lifecycle":
            if i + 1 < args.count {
                if let mode = HostLifecycle(rawValue: args[i + 1]) {
                    lifecycle = mode
                }
                i += 1
            }
        default:
            break
        }
        i += 1
    }

    guard let path = socketPath else { return nil }
    return HostArguments(socketPath: path, lifecycle: lifecycle)
}

guard let arguments = parseArguments() else {
    fputs("Usage: ETermExtensionHost --socket <path> [--lifecycle <mode>]\n", stderr)
    fputs("Lifecycle modes: exitWithClient, persist1Hour, persist5Hours, persist24Hours, persistForever\n", stderr)
    exit(1)
}

fputs("[ExtensionHost] Socket path: \(arguments.socketPath)\n", stderr)
fputs("[ExtensionHost] Lifecycle: \(arguments.lifecycle.rawValue)\n", stderr)

// Create and run Host
fputs("[ExtensionHost] Creating host...\n", stderr)
let host = ExtensionHost(socketPath: arguments.socketPath, lifecycle: arguments.lifecycle)
fputs("[ExtensionHost] Host created, starting run loop...\n", stderr)

// Use RunLoop to keep running
Task {
    do {
        try await host.run()
    } catch {
        fputs("Extension Host error: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
