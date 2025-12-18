/**
 * 简约标签组件
 * 朴素圆角设计，配色跟随水墨主题
 */
import SwiftUI
import AppKit

// MARK: - 简约 Tab 视图
struct SimpleTabView: View {
    let text: String
    let emoji: String?
    let isActive: Bool
    let needsAttention: Bool
    let height: CGFloat
    let isHovered: Bool  // 由外部控制的 hover 状态
    let onClose: (() -> Void)?

    // 批量关闭回调
    let onCloseOthers: (() -> Void)?
    let onCloseLeft: (() -> Void)?
    let onCloseRight: (() -> Void)?

    // 是否可以关闭左侧/右侧（边界情况禁用）
    let canCloseLeft: Bool
    let canCloseRight: Bool
    let canCloseOthers: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String, emoji: String? = nil, isActive: Bool = false, needsAttention: Bool = false, height: CGFloat = 28, isHovered: Bool = false, onClose: (() -> Void)? = nil, onCloseOthers: (() -> Void)? = nil, onCloseLeft: (() -> Void)? = nil, onCloseRight: (() -> Void)? = nil, canCloseLeft: Bool = true, canCloseRight: Bool = true, canCloseOthers: Bool = true) {
        self.text = text
        self.emoji = emoji
        self.isActive = isActive
        self.needsAttention = needsAttention
        self.height = height
        self.isHovered = isHovered
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onCloseLeft = onCloseLeft
        self.onCloseRight = onCloseRight
        self.canCloseLeft = canCloseLeft
        self.canCloseRight = canCloseRight
        self.canCloseOthers = canCloseOthers
    }

    // MARK: - 配色（跟随水墨主题）

    /// 激活状态背景色
    private var activeBackground: Color {
        if needsAttention {
            // 需要注意 - 橙色调
            return colorScheme == .dark
                ? Color.orange.opacity(0.3)
                : Color.orange.opacity(0.2)
        }
        // 激活 - 深红/墨色
        return colorScheme == .dark
            ? Color(hex: "861717").opacity(0.6)
            : Color(hex: "861717").opacity(0.4)
    }

    /// 未激活状态背景色
    private var inactiveBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    /// Hover 状态背景色
    private var hoverBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.1)
    }

    /// 文字颜色
    private var textColor: Color {
        if needsAttention {
            return colorScheme == .dark ? Color.orange : Color.orange.opacity(0.9)
        }
        if isActive {
            return colorScheme == .dark ? Color.white : Color.white
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.7)
            : Color.black.opacity(0.6)
    }

    /// 关闭按钮颜色
    private var closeButtonColor: Color {
        if isActive || needsAttention {
            return Color.white.opacity(0.7)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.5)
            : Color.black.opacity(0.4)
    }

    /// 圆角大小
    private var cornerRadius: CGFloat { height * 0.25 }

    /// 固定宽度
    private var tabWidth: CGFloat { 180 }

    var body: some View {
        HStack(spacing: 6) {
            // 左侧：emoji + 文字
            HStack(spacing: 4) {
                if let emoji = emoji {
                    Text(emoji)
                        .font(.system(size: height * 0.5))
                }

                Text(text)
                    .font(.system(size: height * 0.4))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // 右侧：关闭按钮（Button 会自动优先响应，不被外层手势拦截）
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: height * 0.28, weight: .medium))
                        .foregroundColor(isHovered ? textColor : closeButtonColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: tabWidth, height: height)
        .contentShape(Rectangle())  // 整个 Tab 可点击
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)
        )
        // 右键菜单
        .contextMenu {
            if let onClose = onClose {
                Button("关闭") { onClose() }
            }
            if let onCloseOthers = onCloseOthers, canCloseOthers {
                Button("关闭其他") { onCloseOthers() }
            }
            if let onCloseLeft = onCloseLeft, canCloseLeft {
                Button("关闭左侧") { onCloseLeft() }
            }
            if let onCloseRight = onCloseRight, canCloseRight {
                Button("关闭右侧") { onCloseRight() }
            }
        }
        // 点击手势由外层处理（PageTabView），这里只负责显示
        // hover 状态由外部 AppKit 的 NSTrackingArea 控制
    }

    private var backgroundColor: Color {
        if isActive || needsAttention {
            return activeBackground
        }
        return isHovered ? hoverBackground : inactiveBackground
    }
}

// MARK: - Preview
#Preview("Simple Tab - Dark") {
    VStack(spacing: 16) {
        HStack(spacing: 8) {
            SimpleTabView("终端 1", isActive: true, height: 26, onClose: { })
            SimpleTabView("终端 2", isActive: false, height: 26, onClose: { })
            SimpleTabView("Claude", isActive: false, needsAttention: true, height: 26, onClose: { })
        }

        HStack(spacing: 8) {
            SimpleTabView("Page 1", isActive: true, height: 22, onClose: nil)
            SimpleTabView("Page 2", isActive: false, height: 22, onClose: nil)
            SimpleTabView("Settings", isActive: false, height: 22, onClose: { })
        }
    }
    .padding(40)
    .background(Color.black.opacity(0.8))
    .preferredColorScheme(.dark)
}

#Preview("Simple Tab - Light") {
    VStack(spacing: 16) {
        HStack(spacing: 8) {
            SimpleTabView("终端 1", isActive: true, height: 26, onClose: { })
            SimpleTabView("终端 2", isActive: false, height: 26, onClose: { })
            SimpleTabView("Claude", isActive: false, needsAttention: true, height: 26, onClose: { })
        }

        HStack(spacing: 8) {
            SimpleTabView("Page 1", isActive: true, height: 22, onClose: nil)
            SimpleTabView("Page 2", isActive: false, height: 22, onClose: nil)
            SimpleTabView("Settings", isActive: false, height: 22, onClose: { })
        }
    }
    .padding(40)
    .background(Color(red: 10/255, green: 87/255, blue: 64/255).opacity(0.2))
    .preferredColorScheme(.light)
}
