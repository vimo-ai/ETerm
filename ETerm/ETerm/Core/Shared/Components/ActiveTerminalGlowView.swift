//
//  ActiveTerminalGlowView.swift
//  ETerm
//
//  Active 终端内发光边框效果
//
//  灵感来源：Apple Intelligence 的发光边框效果
//  实现：固定颜色 + 轻微呼吸动画
//

import AppKit
import SwiftUI

// MARK: - 内发光边框视图（SwiftUI）

/// 内发光边框视图
///
/// 固定颜色 + 轻微呼吸效果的内发光边框
struct InnerGlowBorderView: View {
    let cornerRadius: CGFloat
    let glowWidth: CGFloat

    // 固定颜色：Apple Intelligence 风格的 teal/cyan
    private let glowColor = Color(red: 74.0/255.0, green: 153.0/255.0, blue: 146.0/255.0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // 3 秒呼吸周期，使用 sin 函数实现平滑过渡
            let breathPhase = (sin(time * .pi / 1.5) + 1) / 2  // 0 ~ 1
            // 呼吸范围：0.15 ~ 0.3（轻微变化）
            let breathOpacity = 0.15 + breathPhase * 0.15

            Canvas { ctx, size in
                drawInnerGlowBorder(ctx: ctx, size: size, opacity: breathOpacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// 绘制内发光边框
    private func drawInnerGlowBorder(ctx: GraphicsContext, size: CGSize, opacity: Double) {
        // 生成圆角矩形路径
        let path = RoundedRectangle(cornerRadius: cornerRadius)
            .path(in: CGRect(origin: .zero, size: size))

        // 固定颜色样式
        let colorStyle = GraphicsContext.Shading.color(glowColor)

        // 多层绘制实现内发光效果

        // 第 1 层：最外层柔和光晕（最模糊）
        var glowCtx1 = ctx
        glowCtx1.opacity = opacity * 0.4
        glowCtx1.addFilter(.blur(radius: glowWidth * 1.2))
        glowCtx1.stroke(
            path,
            with: colorStyle,
            style: StrokeStyle(lineWidth: glowWidth * 2.5, lineCap: .round, lineJoin: .round)
        )

        // 第 2 层：中间光晕
        var glowCtx2 = ctx
        glowCtx2.opacity = opacity * 0.6
        glowCtx2.addFilter(.blur(radius: glowWidth * 0.6))
        glowCtx2.stroke(
            path,
            with: colorStyle,
            style: StrokeStyle(lineWidth: glowWidth * 1.5, lineCap: .round, lineJoin: .round)
        )

        // 第 3 层：内层光晕
        var glowCtx3 = ctx
        glowCtx3.opacity = opacity * 0.8
        glowCtx3.addFilter(.blur(radius: glowWidth * 0.2))
        glowCtx3.stroke(
            path,
            with: colorStyle,
            style: StrokeStyle(lineWidth: glowWidth * 0.8, lineCap: .round, lineJoin: .round)
        )

        // 第 4 层：核心边框（最清晰）
        var coreCtx = ctx
        coreCtx.opacity = opacity
        coreCtx.stroke(
            path,
            with: colorStyle,
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - NSView 包装

/// Active 终端内发光视图（AppKit）
///
/// 用于在终端内容区域显示内发光边框效果
final class ActiveTerminalGlowView: NSView {
    // MARK: - 属性

    /// SwiftUI hosting view
    private var hostingView: NSHostingView<InnerGlowBorderView>?

    /// 圆角半径
    private let cornerRadius: CGFloat = 8

    /// 发光宽度
    private let glowWidth: CGFloat = 12

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 创建 SwiftUI 视图
        let glowView = InnerGlowBorderView(cornerRadius: cornerRadius, glowWidth: glowWidth)
        let hosting = NSHostingView(rootView: glowView)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }
}

// MARK: - Preview

#Preview("InnerGlowBorder") {
    ZStack {
        Color.black

        RoundedRectangle(cornerRadius: 8)
            .fill(Color(white: 0.1))
            .frame(width: 400, height: 300)
            .overlay(InnerGlowBorderView(cornerRadius: 8, glowWidth: 12))
    }
    .frame(width: 500, height: 400)
}
