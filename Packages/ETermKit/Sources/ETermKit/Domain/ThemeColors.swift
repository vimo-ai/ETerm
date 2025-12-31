// ThemeColors.swift
// ETermKit
//
// Shuimo 主题颜色常量
// 同步：Rust 侧 rio/rio-backend/src/config/colors/defaults.rs

import AppKit

/// Shuimo 主题颜色
public enum ThemeColors {
    /// 主色调（青绿色 #2AD98D）
    public static let accent = NSColor(red: 0x2A/255.0, green: 0xD9/255.0, blue: 0x8D/255.0, alpha: 1.0)

    /// 主色调 Hex 值
    public static let accentHex = "2AD98D"
}
