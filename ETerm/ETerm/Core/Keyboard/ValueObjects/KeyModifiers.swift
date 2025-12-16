//
//  KeyModifiers.swift
//  ETerm
//
//  领域层 - 修饰键值对象

import AppKit

/// 修饰键 - 值对象
struct KeyModifiers: OptionSet, Hashable {
    let rawValue: UInt

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift   = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let option  = KeyModifiers(rawValue: 1 << 3)

    /// 从 NSEvent.ModifierFlags 构造
    static func from(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result = KeyModifiers()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift)   { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option)  { result.insert(.option) }
        return result
    }

    /// 是否有任何修饰键
    var hasAny: Bool {
        !isEmpty
    }

    /// 是否只有 Shift
    var isShiftOnly: Bool {
        self == .shift
    }

    /// 转换为 Rust FFI 的 modifier 位格式
    ///
    /// Rust 端格式：
    /// - bit 0: Shift
    /// - bit 1: Control
    /// - bit 2: Option (Alt)
    /// - bit 3: Command (Meta)
    func toRustFlags() -> UInt32 {
        var result: UInt32 = 0
        if contains(.shift)   { result |= 1 << 0 }
        if contains(.control) { result |= 1 << 1 }
        if contains(.option)  { result |= 1 << 2 }
        if contains(.command) { result |= 1 << 3 }
        return result
    }
}
