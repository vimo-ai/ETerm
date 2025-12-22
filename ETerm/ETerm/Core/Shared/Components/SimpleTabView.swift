/**
 * 简约标签组件
 * 朴素圆角设计，配色跟随水墨主题
 */
import SwiftUI
import AppKit

// MARK: - 简约 Tab 视图
struct SimpleTabView: View {
    let text: String
    let isActive: Bool
    let decoration: TabDecoration?
    let width: CGFloat?  // 动态宽度，nil 时使用默认值
    let height: CGFloat
    let isHovered: Bool  // 由外部控制的 hover 状态
    let slotViews: [AnyView]  // 插件注入的 slot 视图
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

    // 动画状态
    @State private var animationPhase: CGFloat = 0

    /// 默认宽度（兼容旧代码）
    private static let defaultWidth: CGFloat = 180

    init(
        _ text: String,
        isActive: Bool = false,
        decoration: TabDecoration? = nil,
        width: CGFloat? = nil,
        height: CGFloat = 28,
        isHovered: Bool = false,
        slotViews: [AnyView] = [],
        onClose: (() -> Void)? = nil,
        onCloseOthers: (() -> Void)? = nil,
        onCloseLeft: (() -> Void)? = nil,
        onCloseRight: (() -> Void)? = nil,
        canCloseLeft: Bool = true,
        canCloseRight: Bool = true,
        canCloseOthers: Bool = true
    ) {
        self.text = text
        self.isActive = isActive
        self.decoration = decoration
        self.width = width
        self.height = height
        self.isHovered = isHovered
        self.slotViews = slotViews
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onCloseLeft = onCloseLeft
        self.onCloseRight = onCloseRight
        self.canCloseLeft = canCloseLeft
        self.canCloseRight = canCloseRight
        self.canCloseOthers = canCloseOthers
    }

    // MARK: - 兼容旧 API

    /// 是否有装饰（兼容 needsAttention 的判断逻辑）
    private var hasDecoration: Bool {
        decoration != nil
    }

    // MARK: - 配色（跟随水墨主题）

    /// 装饰颜色（从 TabDecoration 获取，转换为 SwiftUI Color）
    private var decorationColor: Color {
        guard let decoration = decoration else {
            return Color.clear
        }
        return Color(nsColor: decoration.color)
    }

    /// 激活状态背景色
    private var activeBackground: Color {
        if let decoration = decoration {
            // 有装饰时使用装饰颜色
            let baseOpacity: CGFloat = colorScheme == .dark ? 0.3 : 0.2
            let opacity = animatedOpacity(baseOpacity: baseOpacity)
            return Color(nsColor: decoration.color).opacity(opacity)
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
        if let decoration = decoration {
            return Color(nsColor: decoration.color)
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
        if isActive || hasDecoration {
            return Color.white.opacity(0.7)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.5)
            : Color.black.opacity(0.4)
    }

    /// 圆角大小
    private var cornerRadius: CGFloat { height * 0.25 }

    /// 实际宽度（使用传入的宽度或默认值）
    private var tabWidth: CGFloat { width ?? Self.defaultWidth }

    // MARK: - 动画

    /// 根据装饰样式计算动画透明度
    private func animatedOpacity(baseOpacity: CGFloat) -> CGFloat {
        guard let decoration = decoration else {
            return baseOpacity
        }

        switch decoration.style {
        case .solid:
            return baseOpacity
        case .pulse:
            // 脉冲动画：透明度在 0.2 ~ 0.5 之间变化
            let minOpacity = baseOpacity * 0.5
            let maxOpacity = baseOpacity * 1.5
            return minOpacity + (maxOpacity - minOpacity) * animationPhase
        case .breathing:
            // 呼吸动画：更柔和的透明度变化
            let minOpacity = baseOpacity * 0.7
            let maxOpacity = baseOpacity * 1.3
            return minOpacity + (maxOpacity - minOpacity) * animationPhase
        }
    }

    /// 动画时长
    private var animationDuration: Double {
        guard let decoration = decoration else { return 0 }
        switch decoration.style {
        case .solid:
            return 0
        case .pulse:
            return 0.8  // 快速脉冲
        case .breathing:
            return 2.0  // 慢速呼吸
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // 左侧：标题
            Text(text)
                .font(.system(size: height * 0.4))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // 中间：Slot 区域（插件注入的视图，最大 40px）
            if !slotViews.isEmpty {
                HStack(spacing: 2) {
                    ForEach(slotViews.indices, id: \.self) { index in
                        slotViews[index]
                    }
                }
                .frame(maxWidth: 40)
            }

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
        // 动画
        .onAppear {
            startAnimationIfNeeded()
        }
        .onChange(of: decoration) { _, newValue in
            if newValue != nil {
                startAnimationIfNeeded()
            } else {
                animationPhase = 0
            }
        }
    }

    private var backgroundColor: Color {
        if isActive || hasDecoration {
            return activeBackground
        }
        return isHovered ? hoverBackground : inactiveBackground
    }

    private func startAnimationIfNeeded() {
        guard let decoration = decoration, decoration.style != .solid else {
            return
        }

        // 重置动画
        animationPhase = 0

        // 使用循环动画
        withAnimation(
            Animation
                .easeInOut(duration: animationDuration)
                .repeatForever(autoreverses: true)
        ) {
            animationPhase = 1.0
        }
    }
}

// MARK: - Preview
#Preview("Simple Tab - Dark") {
    VStack(spacing: 16) {
        HStack(spacing: 8) {
            SimpleTabView("终端 1", isActive: true, height: 26, onClose: { })
            SimpleTabView("终端 2", isActive: false, height: 26, onClose: { })
            SimpleTabView(
                "Claude Running",
                isActive: false,
                decoration: .completed(pluginId: "preview"),
                height: 26,
                onClose: { }
            )
        }

        HStack(spacing: 8) {
            SimpleTabView(
                "AI Thinking",
                isActive: false,
                decoration: .thinking(pluginId: "preview"),
                height: 26,
                onClose: { }
            )
            SimpleTabView(
                "Completed",
                isActive: false,
                decoration: .completed(pluginId: "preview"),
                height: 26,
                onClose: { }
            )
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
            SimpleTabView(
                "Claude Running",
                isActive: false,
                decoration: .completed(pluginId: "preview"),
                height: 26,
                onClose: { }
            )
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
