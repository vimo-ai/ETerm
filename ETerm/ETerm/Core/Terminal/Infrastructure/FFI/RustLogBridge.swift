//
//  RustLogBridge.swift
//  ETerm
//
//  Rust → Swift 日志桥接
//  将 Rust 端的关键日志转发到 Swift LogManager，实现日志持久化
//

import Foundation
import ETermKit

/// Rust 日志桥接管理器
class RustLogBridge {

    // MARK: - Singleton

    static let shared = RustLogBridge()

    // MARK: - Properties

    /// 回调是否已设置
    private var isCallbackSet = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// 设置 Rust 日志回调
    ///
    /// 应该在 App 启动时调用一次
    func setupCallback() {
        guard !isCallbackSet else {
            logWarn("RustLogBridge: callback already set")
            return
        }

        // 创建回调闭包（必须使用 @convention(c) 以兼容 C ABI）
        let callback: @convention(c) (RustLogLevel, UnsafePointer<CChar>?) -> Void = { level, message in
            guard let message = message else { return }
            let text = String(cString: message)

            // 根据日志级别转发到 LogManager
            // 注意：LogManager 是线程安全的（内部使用串行队列）
            switch level {
            case RustLogLevel_Debug:
                LogManager.shared.debug(text)

            case RustLogLevel_Info:
                LogManager.shared.info(text)

            case RustLogLevel_Warn:
                LogManager.shared.warn(text)

            case RustLogLevel_Error:
                LogManager.shared.error(text)

            default:
                // 未知级别，使用 info
                LogManager.shared.info(text)
            }
        }

        // 设置回调到 Rust 端
        set_rust_log_callback(callback)
        isCallbackSet = true

        logInfo("RustLogBridge: callback setup completed")
    }

    /// 清除回调（通常不需要调用）
    func clearCallback() {
        guard isCallbackSet else { return }

        clear_rust_log_callback()
        isCallbackSet = false

        logInfo("RustLogBridge: callback cleared")
    }
}

// MARK: - Global Convenience Function

/// 初始化 Rust 日志桥接
///
/// 应该在 App 启动时调用
func setupRustLogBridge() {
    RustLogBridge.shared.setupCallback()
}
