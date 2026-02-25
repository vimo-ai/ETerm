//
//  DevRunnerModels.swift
//  DevRunnerKit
//
//  Codable DTOs mirroring the Rust FFI JSON types.

import Foundation

// MARK: - Project & Target

public struct ProjectInfo: Codable, Identifiable, Equatable {
    public var id: String { path }
    public let adapterType: String   // "xcode", "node"
    public let name: String
    public let path: String
    public let bundleId: String?

    public enum CodingKeys: String, CodingKey {
        case adapterType = "adapter_type"
        case name, path
        case bundleId = "bundle_id"
    }
}

public struct TargetInfo: Codable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let targetType: String    // "scheme", "script"
    public let description: String?

    public enum CodingKeys: String, CodingKey {
        case name
        case targetType = "target_type"
        case description
    }
}

// MARK: - Commands

public struct CommandInfo: Codable {
    public let program: String
    public let args: [String]
    public let cwd: String?
    public let env: [String: String]
    public let display: String
}

// MARK: - Process

/// 监控模式进程启动结果（shell tab + sendInput 模式）
public struct MonitoredProcessResult: Codable {
    public let processId: String
    public let wrappedCommand: String
    public let cwd: String

    public enum CodingKeys: String, CodingKey {
        case processId = "process_id"
        case wrappedCommand = "wrapped_command"
        case cwd
    }
}

public struct ProcessInfo: Codable, Identifiable, Equatable {
    public var id: String { processId }
    public let processId: String          // UUID
    public let projectPath: String
    public let adapterType: String
    public let target: String
    public let pid: UInt32?
    public let status: String            // "running", "stopped", "failed"
    public let errorMessage: String?
    public let startedAt: Int64
    public let endedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case processId = "id"            // Rust serializes the field as "id"
        case projectPath = "project_path"
        case adapterType = "adapter_type"
        case target, pid, status
        case errorMessage = "error_message"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public var isRunning: Bool { status == "running" }
}

// MARK: - Metrics

public struct MetricsInfo: Codable {
    public let pid: UInt32
    public let cpuPercent: Float
    public let memoryBytes: UInt64
    public let timestamp: Int64

    public enum CodingKeys: String, CodingKey {
        case pid
        case cpuPercent = "cpu_percent"
        case memoryBytes = "memory_bytes"
        case timestamp
    }

    /// 格式化内存显示
    public var formattedMemory: String {
        let mb = Double(memoryBytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Errors

public enum DevRunnerError: Error, LocalizedError {
    case ffiError(String)
    case nullResult
    case handleNotInitialized
    case jsonDecodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffiError(let msg):          return "DevRunner FFI: \(msg)"
        case .nullResult:                 return "DevRunner: null result from FFI"
        case .handleNotInitialized:       return "DevRunner: handle not initialized"
        case .jsonDecodingFailed(let msg): return "DevRunner JSON: \(msg)"
        }
    }
}
