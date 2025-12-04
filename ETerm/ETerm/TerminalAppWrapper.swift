//
//  TerminalAppWrapper.swift
//  ETerm
//
//  新架构 FFI 封装（TerminalApp）
//

import Foundation
import AppKit

// MARK: - C-compatible 类型定义

/// 应用配置（C-compatible）
struct AppConfig {
    var cols: UInt16
    var rows: UInt16
    var font_size: Float
    var line_height: Float
    var scale: Float
    var window_handle: UnsafeMutableRawPointer?
    var display_handle: UnsafeMutableRawPointer?
    var window_width: Float
    var window_height: Float
    var history_size: UInt32
}

/// 错误码
enum ErrorCode: UInt32 {
    case success = 0
    case nullPointer = 1
    case invalidConfig = 2
    case invalidUtf8 = 3
    case renderError = 4
    case outOfBounds = 5
}

/// 终端事件类型
enum TerminalEventType: UInt32 {
    case cursorBlink = 0
    case bell = 1
    case titleChanged = 2
    case damaged = 3
}

/// 终端事件（FFI 类型，与 EventPayloads.swift 的 TerminalEvent 不同）
struct FFITerminalEvent {
    var event_type: UInt32
    var data: UInt64
}

/// 网格坐标
struct GridPoint {
    var col: UInt16
    var row: UInt16
}

// MARK: - TerminalAppWrapper

/// 新架构 TerminalApp 的 Swift 封装
///
/// 关键架构：
/// - Rust 侧创建 Sugarloaf，Swift 只传递 NSView 指针
/// - Swift 调用 `terminal_app_render()` 一次，Rust 批量渲染所有行
/// - 收到 `Damaged` 事件时触发渲染
class TerminalAppWrapper {
    private var appHandle: OpaquePointer?
    private var eventCallback: ((FFITerminalEvent) -> Void)?

    // MARK: - 生命周期

    /// 创建终端应用
    init?(config: AppConfig) {
        var mutableConfig = config
        self.appHandle = terminal_app_create(mutableConfig)

        guard self.appHandle != nil else {
            print("⚠️ [TerminalAppWrapper] Failed to create TerminalApp")
            return nil
        }

        print("✅ [TerminalAppWrapper] Created successfully")
    }

    deinit {
        if let handle = appHandle {
            terminal_app_destroy(handle)
            print("🗑️ [TerminalAppWrapper] Destroyed")
        }
    }

    // MARK: - 核心功能

    /// 写入数据
    func write(data: String) -> Bool {
        guard let handle = appHandle else { return false }

        guard let utf8Data = data.data(using: .utf8) else {
            print("⚠️ [TerminalAppWrapper] Invalid UTF-8 string")
            return false
        }

        let result = utf8Data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> ErrorCode in
            let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let errorCode = terminal_app_write(handle, ptr, UInt(bytes.count))
            return ErrorCode(rawValue: errorCode) ?? .nullPointer
        }

        return result == .success
    }

    /// 渲染（批量渲染所有行到 Metal）
    func render() -> Bool {
        guard let handle = appHandle else { return false }

        let errorCode = terminal_app_render(handle)
        let result = ErrorCode(rawValue: errorCode) ?? .nullPointer

        if result != .success {
            print("⚠️ [TerminalAppWrapper] Render failed: \(result)")
        }

        return result == .success
    }

    /// 调整大小
    func resize(cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = appHandle else { return false }

        let errorCode = terminal_app_resize(handle, cols, rows)
        let result = ErrorCode(rawValue: errorCode) ?? .nullPointer

        if result == .success {
            print("✅ [TerminalAppWrapper] Resized to \(cols)x\(rows)")
        } else {
            print("⚠️ [TerminalAppWrapper] Resize failed: \(result)")
        }

        return result == .success
    }

    // MARK: - 选区

    /// 开始选区
    func startSelection(point: GridPoint) -> Bool {
        guard let handle = appHandle else { return false }

        var mutablePoint = point
        let errorCode = terminal_app_start_selection(handle, mutablePoint)
        return ErrorCode(rawValue: errorCode) == .success
    }

    /// 更新选区
    func updateSelection(point: GridPoint) -> Bool {
        guard let handle = appHandle else { return false }

        var mutablePoint = point
        let errorCode = terminal_app_update_selection(handle, mutablePoint)
        return ErrorCode(rawValue: errorCode) == .success
    }

    /// 清除选区
    func clearSelection() -> Bool {
        guard let handle = appHandle else { return false }

        let errorCode = terminal_app_clear_selection(handle)
        return ErrorCode(rawValue: errorCode) == .success
    }

    /// 获取选区文本
    func getSelectionText() -> String? {
        guard let handle = appHandle else { return nil }

        // 分配 buffer（最大 64KB）
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var written: UInt = 0

        let errorCode = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> ErrorCode in
            let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let code = terminal_app_get_selection_text(handle, ptr, UInt(bufferSize), &written)
            return ErrorCode(rawValue: code) ?? .nullPointer
        }

        guard errorCode == .success, written > 0 else { return nil }

        let data = Data(buffer.prefix(Int(written)))
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 搜索

    /// 搜索文本
    func search(pattern: String) -> UInt {
        guard let handle = appHandle else { return 0 }

        return pattern.withCString { cStr in
            return terminal_app_search(handle, cStr)
        }
    }

    /// 下一个匹配
    func searchNext() -> Bool {
        guard let handle = appHandle else { return false }
        return terminal_app_next_match(handle)
    }

    /// 上一个匹配
    func searchPrev() -> Bool {
        guard let handle = appHandle else { return false }
        return terminal_app_prev_match(handle)
    }

    /// 清除搜索
    func clearSearch() -> Bool {
        guard let handle = appHandle else { return false }
        return terminal_app_clear_search(handle)
    }

    // MARK: - 滚动

    /// 滚动
    func scroll(deltaLines: Int32) -> Bool {
        guard let handle = appHandle else { return false }

        let errorCode = terminal_app_scroll(handle, deltaLines)
        return ErrorCode(rawValue: errorCode) == .success
    }

    // MARK: - 事件回调

    /// 设置事件回调
    func setEventCallback(_ callback: @escaping (FFITerminalEvent) -> Void) {
        guard let handle = appHandle else { return }

        // 保存 callback
        self.eventCallback = callback

        // 传递 self 作为 context
        let context = Unmanaged.passUnretained(self).toOpaque()

        // C 回调：接收分离的参数，然后重组为 FFITerminalEvent
        terminal_app_set_event_callback(
            handle,
            { (contextPtr, eventType, eventData) in
                guard let contextPtr = contextPtr else { return }

                // 恢复 self 引用
                let wrapper = Unmanaged<TerminalAppWrapper>.fromOpaque(contextPtr).takeUnretainedValue()

                // 重组为 FFITerminalEvent
                let event = FFITerminalEvent(event_type: eventType, data: eventData)

                // 调用 Swift 回调
                wrapper.eventCallback?(event)
            },
            context
        )
    }

    // MARK: - 其他

    /// 获取光标位置（暂未实现）
    func getCursor() -> (col: UInt16, row: UInt16)? {
        // TODO: Rust 侧暂未实现 terminal_app_get_cursor
        return nil
    }
}

// MARK: - FFI 函数声明

/// 创建终端应用
@_silgen_name("terminal_app_create")
func terminal_app_create(_ config: AppConfig) -> OpaquePointer?

/// 销毁终端应用
@_silgen_name("terminal_app_destroy")
func terminal_app_destroy(_ handle: OpaquePointer)

/// 写入数据
@_silgen_name("terminal_app_write")
func terminal_app_write(_ handle: OpaquePointer, _ data: UnsafePointer<UInt8>?, _ len: UInt) -> UInt32

/// 渲染
@_silgen_name("terminal_app_render")
func terminal_app_render(_ handle: OpaquePointer) -> UInt32

/// 调整大小
@_silgen_name("terminal_app_resize")
func terminal_app_resize(_ handle: OpaquePointer, _ cols: UInt16, _ rows: UInt16) -> UInt32

/// 开始选区
@_silgen_name("terminal_app_start_selection")
func terminal_app_start_selection(_ handle: OpaquePointer, _ point: GridPoint) -> UInt32

/// 更新选区
@_silgen_name("terminal_app_update_selection")
func terminal_app_update_selection(_ handle: OpaquePointer, _ point: GridPoint) -> UInt32

/// 清除选区
@_silgen_name("terminal_app_clear_selection")
func terminal_app_clear_selection(_ handle: OpaquePointer) -> UInt32

/// 获取选区文本
@_silgen_name("terminal_app_get_selection_text")
func terminal_app_get_selection_text(
    _ handle: OpaquePointer,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ bufferLen: UInt,
    _ written: UnsafeMutablePointer<UInt>?
) -> UInt32

/// 搜索文本
@_silgen_name("terminal_app_search")
func terminal_app_search(_ handle: OpaquePointer, _ pattern: UnsafePointer<CChar>) -> UInt

/// 下一个匹配
@_silgen_name("terminal_app_next_match")
func terminal_app_next_match(_ handle: OpaquePointer) -> Bool

/// 上一个匹配
@_silgen_name("terminal_app_prev_match")
func terminal_app_prev_match(_ handle: OpaquePointer) -> Bool

/// 清除搜索
@_silgen_name("terminal_app_clear_search")
func terminal_app_clear_search(_ handle: OpaquePointer) -> Bool

/// 滚动
@_silgen_name("terminal_app_scroll")
func terminal_app_scroll(_ handle: OpaquePointer, _ deltaLines: Int32) -> UInt32

// 获取光标位置 - 暂未实现，注释掉避免链接错误
// @_silgen_name("terminal_app_get_cursor")
// func terminal_app_get_cursor(
//     _ handle: OpaquePointer,
//     _ col: UnsafeMutablePointer<UInt16>,
//     _ row: UnsafeMutablePointer<UInt16>
// ) -> Bool

/// 设置事件回调
/// C 回调签名：void (*callback)(void* context, uint32_t event_type, uint64_t data)
@_silgen_name("terminal_app_set_event_callback")
func terminal_app_set_event_callback(
    _ handle: OpaquePointer,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt64) -> Void,
    _ context: UnsafeMutableRawPointer?
)
