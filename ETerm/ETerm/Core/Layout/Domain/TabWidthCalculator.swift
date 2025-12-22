//
//  TabWidthCalculator.swift
//  ETerm
//
//  Tab 宽度计算器
//  预计算 + 缓存，不依赖 SwiftUI 渲染时机

import Foundation
import AppKit

/// Tab 宽度计算器
///
/// 使用 NSAttributedString 预计算文字宽度，配合 min/max 约束
/// 支持缓存避免频繁测量
final class TabWidthCalculator {
    static let shared = TabWidthCalculator()

    // MARK: - 常量

    /// 最小宽度
    static let minWidth: CGFloat = 100

    /// 最大宽度
    static let maxWidth: CGFloat = 200

    /// 左右 padding
    private static let horizontalPadding: CGFloat = 20

    /// 关闭按钮宽度
    private static let closeButtonWidth: CGFloat = 20

    /// 内容间距（SimpleTabView 外层 HStack spacing + Spacer 最小宽度）
    private static let contentSpacing: CGFloat = 14  // 6(spacing) + 8(Spacer min)

    /// Slot 区域最大宽度
    private static let slotMaxWidth: CGFloat = 40

    /// 字体大小（对应 SimpleTabView 的 height * 0.4，height = 26）
    private static let fontSize: CGFloat = 10.4

    // MARK: - 缓存

    /// 文字宽度缓存：title -> textWidth
    private var textWidthCache: [String: CGFloat] = [:]

    /// 缓存锁
    private let lock = NSLock()

    /// 缓存上限（防止内存泄漏）
    private let maxCacheSize = 500

    private init() {}

    // MARK: - 公开方法

    /// 计算 Tab 理想宽度
    ///
    /// - Parameters:
    ///   - title: Tab 标题
    ///   - slotWidth: Slot 实际宽度（0 表示无 slot）
    /// - Returns: 约束在 min/max 范围内的宽度
    func calculate(title: String, slotWidth: CGFloat = 0) -> CGFloat {
        let textWidth = measureTextWidth(title)
        let idealWidth = textWidth
            + Self.horizontalPadding
            + Self.contentSpacing
            + Self.closeButtonWidth
            + slotWidth

        return min(max(idealWidth, Self.minWidth), Self.maxWidth)
    }

    /// 批量计算并按容器宽度分配（Safari 模式）
    ///
    /// - Parameters:
    ///   - titles: Tab 标题列表
    ///   - slotWidths: 对应的 slot 宽度列表
    ///   - availableWidth: 容器可用宽度
    ///   - spacing: Tab 间距
    /// - Returns: 分配后的宽度列表
    func distribute(
        titles: [String],
        slotWidths: [CGFloat],
        availableWidth: CGFloat,
        spacing: CGFloat = 4
    ) -> [CGFloat] {
        guard !titles.isEmpty else { return [] }

        // 1. 计算每个 tab 的理想宽度
        let idealWidths = zip(titles, slotWidths).map { title, slotWidth in
            calculate(title: title, slotWidth: slotWidth)
        }

        // 2. 计算总理想宽度（包含间距）
        let totalSpacing = CGFloat(titles.count - 1) * spacing
        let totalIdeal = idealWidths.reduce(0, +) + totalSpacing

        // 3. 如果够用，直接返回理想宽度
        if totalIdeal <= availableWidth {
            return idealWidths
        }

        // 4. 不够用，按比例压缩（但不低于 minWidth）
        let availableForTabs = availableWidth - totalSpacing
        let totalIdealWithoutSpacing = idealWidths.reduce(0, +)
        let ratio = availableForTabs / totalIdealWithoutSpacing

        return idealWidths.map { idealWidth in
            max(idealWidth * ratio, Self.minWidth)
        }
    }

    /// 清除缓存
    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        textWidthCache.removeAll()
    }

    // MARK: - 私有方法

    /// 测量文字宽度（带缓存）
    private func measureTextWidth(_ text: String) -> CGFloat {
        lock.lock()
        defer { lock.unlock() }

        // 检查缓存
        if let cached = textWidthCache[text] {
            return cached
        }

        // 计算宽度（使用 CTLine 更精确）
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attrString = NSAttributedString(string: text, attributes: attributes)

        // CTLine 提供更准确的排版宽度
        let line = CTLineCreateWithAttributedString(attrString)
        let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))

        // 缓存（超限时清理一半）
        if textWidthCache.count >= maxCacheSize {
            let keysToRemove = Array(textWidthCache.keys.prefix(maxCacheSize / 2))
            keysToRemove.forEach { textWidthCache.removeValue(forKey: $0) }
        }
        textWidthCache[text] = width

        return width
    }
}
