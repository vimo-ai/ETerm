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
}
