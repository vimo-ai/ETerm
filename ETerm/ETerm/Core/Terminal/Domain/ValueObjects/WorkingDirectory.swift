//
//  WorkingDirectory.swift
//  ETerm
//
//  工作目录值对象
//
//  职责：
//  - 封装工作目录路径及其来源
//  - 提供不可变性保证
//  - 支持序列化/反序列化
//
//  设计原则：
//  - 值对象：不可变，通过值比较相等性
//  - 携带元数据：来源类型、捕获时间
//  - 支持优先级：用于选择最可靠的 CWD
//

import Foundation

/// 工作目录值对象
///
/// 封装工作目录路径及其元数据，用于追踪 CWD 的来源和可靠性。
/// 作为不可变值对象，每次更新都返回新实例。
struct WorkingDirectory: Equatable, Codable, Sendable {

    // MARK: - Properties

    /// 工作目录路径
    let path: String

    /// 来源类型
    let source: Source

    /// 捕获时间戳（用于判断新鲜度）
    let capturedAt: Date

    // MARK: - Source Type

    /// CWD 来源类型
    ///
    /// 按可靠性从高到低排序：
    /// - osc7Cache: 来自 OSC 7 缓存，shell 主动上报，最可靠
    /// - procPidinfo: 来自 proc_pidinfo 系统调用，可能获取到子进程 CWD
    /// - restored: 来自 Session 恢复，上次保存的值
    /// - inherited: 从其他终端继承（如新建 Tab 时）
    /// - userHome: 默认值，用户主目录
    enum Source: String, Codable, Sendable {
        case osc7Cache      // 来自 OSC 7 缓存（最可靠）
        case procPidinfo    // 来自 proc_pidinfo 系统调用
        case restored       // 来自 Session 恢复
        case inherited      // 从其他终端继承
        case userHome       // 默认值（用户主目录）

        /// 来源描述（用于日志）
        var description: String {
            switch self {
            case .osc7Cache: return "OSC 7 Cache"
            case .procPidinfo: return "proc_pidinfo"
            case .restored: return "Session Restored"
            case .inherited: return "Inherited"
            case .userHome: return "User Home (Default)"
            }
        }
    }

    // MARK: - Initialization

    /// 创建工作目录值对象
    ///
    /// - Parameters:
    ///   - path: 工作目录路径
    ///   - source: 来源类型
    ///   - capturedAt: 捕获时间（默认为当前时间）
    init(path: String, source: Source, capturedAt: Date = Date()) {
        self.path = path
        self.source = source
        self.capturedAt = capturedAt
    }

    // MARK: - Factory Methods

    /// 创建默认工作目录（用户主目录）
    ///
    /// - Returns: 用户主目录的 WorkingDirectory
    static func userHome() -> WorkingDirectory {
        WorkingDirectory(
            path: NSHomeDirectory(),
            source: .userHome
        )
    }

    /// 从 Session 恢复创建
    ///
    /// - Parameter path: 恢复的路径
    /// - Returns: 恢复来源的 WorkingDirectory
    static func restored(path: String) -> WorkingDirectory {
        WorkingDirectory(
            path: path,
            source: .restored
        )
    }

    /// 从 OSC 7 缓存创建
    ///
    /// - Parameter path: OSC 7 上报的路径
    /// - Returns: OSC 7 来源的 WorkingDirectory
    static func fromOSC7(path: String) -> WorkingDirectory {
        WorkingDirectory(
            path: path,
            source: .osc7Cache
        )
    }

    /// 从 proc_pidinfo 创建
    ///
    /// - Parameter path: 系统调用获取的路径
    /// - Returns: procPidinfo 来源的 WorkingDirectory
    static func fromProcPidinfo(path: String) -> WorkingDirectory {
        WorkingDirectory(
            path: path,
            source: .procPidinfo
        )
    }

    /// 从其他终端继承创建
    ///
    /// - Parameter path: 继承的路径
    /// - Returns: 继承来源的 WorkingDirectory
    static func inherited(path: String) -> WorkingDirectory {
        WorkingDirectory(
            path: path,
            source: .inherited
        )
    }

    // MARK: - Computed Properties

    /// 优先级（用于选择最可靠的 CWD）
    ///
    /// 数值越高表示越可靠：
    /// - 100: OSC 7 缓存（shell 主动上报，最可靠）
    /// - 80: proc_pidinfo（系统调用，可能是子进程）
    /// - 60: Session 恢复（上次保存的值）
    /// - 40: 继承（从其他终端复制）
    /// - 0: 用户主目录（默认值，最低优先级）
    var priority: Int {
        switch source {
        case .osc7Cache: return 100
        case .procPidinfo: return 80
        case .restored: return 60
        case .inherited: return 40
        case .userHome: return 0
        }
    }

    /// 是否可靠（可用于持久化）
    ///
    /// 只有来自运行时的 CWD（OSC 7 或 proc_pidinfo）被认为是可靠的，
    /// 因为它们反映了终端的实际状态。
    var isReliable: Bool {
        source == .osc7Cache || source == .procPidinfo
    }

    /// 是否为默认值
    ///
    /// 用于判断是否需要特殊处理（如日志警告）
    var isDefault: Bool {
        source == .userHome
    }

    /// 年龄（秒）
    ///
    /// 用于判断缓存值的新鲜度
    var age: TimeInterval {
        Date().timeIntervalSince(capturedAt)
    }

    /// 是否过期（超过 5 分钟）
    ///
    /// 用于决定是否需要重新获取
    var isStale: Bool {
        age > 300 // 5 分钟
    }

    // MARK: - Comparison

    /// 选择优先级更高的工作目录
    ///
    /// - Parameter other: 另一个 WorkingDirectory
    /// - Returns: 优先级更高的那个
    func preferring(_ other: WorkingDirectory) -> WorkingDirectory {
        if other.priority > self.priority {
            return other
        }
        // 同优先级时选择更新的
        if other.priority == self.priority && other.capturedAt > self.capturedAt {
            return other
        }
        return self
    }

    // MARK: - Path Operations

    /// 路径是否存在
    ///
    /// 用于验证恢复的路径是否仍然有效
    var pathExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// 如果路径不存在，返回用户主目录
    ///
    /// - Returns: 有效的 WorkingDirectory
    func validatedOrUserHome() -> WorkingDirectory {
        if pathExists {
            return self
        }
        return .userHome()
    }
}

// MARK: - CustomStringConvertible

extension WorkingDirectory: CustomStringConvertible {
    var description: String {
        "WorkingDirectory(path: \"\(path)\", source: \(source.description), age: \(Int(age))s)"
    }
}

// MARK: - CustomDebugStringConvertible

extension WorkingDirectory: CustomDebugStringConvertible {
    var debugDescription: String {
        """
        WorkingDirectory {
            path: "\(path)"
            source: \(source.description)
            priority: \(priority)
            isReliable: \(isReliable)
            capturedAt: \(capturedAt)
            age: \(Int(age))s
            isStale: \(isStale)
        }
        """
    }
}
