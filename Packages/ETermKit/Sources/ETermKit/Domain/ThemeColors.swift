// ThemeColors.swift
// ETermKit
//
// Sci-Fi HUD 主题颜色系统
// 同步：Rust 侧 rio/rio-backend/src/config/colors/defaults.rs

import AppKit
import SwiftUI

/// ETerm Sci-Fi HUD 主题颜色
public enum ThemeColors {

    // MARK: - Accent

    /// 主色调（青绿色 #2AD98D）
    public static let accent = NSColor(red: 0x2A/255.0, green: 0xD9/255.0, blue: 0x8D/255.0, alpha: 1.0)
    public static let accentHex = "2AD98D"
    public static let accentDark = NSColor(red: 0x1F/255.0, green: 0xA8/255.0, blue: 0x6B/255.0, alpha: 1.0)

    // MARK: - Backgrounds

    public static let bgPrimary = NSColor(red: 0, green: 0, blue: 0, alpha: 1.0)
    public static let bgSecondary = NSColor(white: 0x0A/255.0, alpha: 1.0)
    public static let bgTertiary = NSColor(white: 0x14/255.0, alpha: 1.0)
    public static let bgHover = NSColor(white: 0x1A/255.0, alpha: 1.0)
    public static let bgCard = NSColor(white: 0x1E/255.0, alpha: 1.0)

    // MARK: - Text

    public static let textPrimary = NSColor(white: 0xE8/255.0, alpha: 1.0)
    public static let textSecondary = NSColor(white: 0x88/255.0, alpha: 1.0)
    public static let textMuted = NSColor(white: 0x55/255.0, alpha: 1.0)

    // MARK: - Border

    public static let border = NSColor(white: 0x2A/255.0, alpha: 1.0)

    // MARK: - Semantic

    public static let success = accent
    public static let warning = NSColor(red: 0xFF/255.0, green: 0xB8/255.0, blue: 0, alpha: 1.0)
    public static let error = NSColor(red: 0xFF/255.0, green: 0x47/255.0, blue: 0x57/255.0, alpha: 1.0)
    public static let info = NSColor.systemBlue

    // MARK: - Tab Decoration

    public static let tabThinking = NSColor.systemBlue
    public static let tabWaitingInput = NSColor.systemYellow
    public static let tabCompleted = NSColor.systemOrange
}

// MARK: - SwiftUI Bridging

public extension ThemeColors {
    enum UI {
        public static let accent = Color(ThemeColors.accent)
        public static let accentDark = Color(ThemeColors.accentDark)

        public static let bgPrimary = Color(ThemeColors.bgPrimary)
        public static let bgSecondary = Color(ThemeColors.bgSecondary)
        public static let bgTertiary = Color(ThemeColors.bgTertiary)
        public static let bgHover = Color(ThemeColors.bgHover)
        public static let bgCard = Color(ThemeColors.bgCard)

        public static let textPrimary = Color(ThemeColors.textPrimary)
        public static let textSecondary = Color(ThemeColors.textSecondary)
        public static let textMuted = Color(ThemeColors.textMuted)

        public static let border = Color(ThemeColors.border)

        public static let success = Color(ThemeColors.success)
        public static let warning = Color(ThemeColors.warning)
        public static let error = Color(ThemeColors.error)
        public static let info = Color(ThemeColors.info)
    }
}
