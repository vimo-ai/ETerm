//
//  SugarloafView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

import SwiftUI
import AppKit

/// NSView that wraps Sugarloaf rendering
class SugarloafNSView: NSView {
    private var sugarloaf: SugarloafWrapper?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSugarloaf()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSugarloaf()
    }

    private func setupSugarloaf() {
        // 确保这是一个 layer-backed view
        // 重要: 不要手动创建 Metal layer，让 WGPU 自己处理
        wantsLayer = true

        print("✅ View is layer-backed (WGPU will create Metal layer)")

        // 等待 window 可用后再初始化 Sugarloaf
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeKey() {
        // 延迟初始化，确保 view 已经完全布局
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initializeSugarloaf()
        }
    }

    private func initializeSugarloaf() {
        guard sugarloaf == nil, let window = window else { return }

        // 确保 bounds 不为零
        guard bounds.width > 0 && bounds.height > 0 else {
            print("⚠️ View bounds is zero, waiting...")
            return
        }

        print("🪟 Window available, initializing Sugarloaf...")
        print("   Window: \(window)")
        print("   View bounds: \(bounds)")
        print("   Scale: \(window.backingScaleFactor)")
        print("   Layer: \(String(describing: layer))")

        // 获取 NSView 的原生句柄 (不是 NSWindow!)
        // Sugarloaf 需要的是 NSView 的指针
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)
        let displayHandle = windowHandle

        let scale = Float(window.backingScaleFactor)
        let width = Float(bounds.width)
        let height = Float(bounds.height)

        print("   Creating Sugarloaf with:")
        print("   - width: \(width), height: \(height)")
        print("   - scale: \(scale)")

        // 初始化 Sugarloaf
        sugarloaf = SugarloafWrapper(
            windowHandle: windowHandle,
            displayHandle: displayHandle,
            width: width,
            height: height,
            scale: scale,
            fontSize: 18.0  // 正常字体大小
        )

        if sugarloaf != nil {
            print("✅ Sugarloaf initialized successfully")
            // 测试渲染一些内容
            renderTestContent()

            // 触发重绘
            needsDisplay = true
        } else {
            print("❌ Failed to initialize Sugarloaf")
        }
    }

    private func renderTestContent() {
        guard let sugarloaf = sugarloaf else { return }

        print("📝 Building test content with RichText...")

        // 清空屏幕 (重要!)
        sugarloaf.clear()

        // 创建富文本
        let rtId = sugarloaf.createRichText()
        print("Created RichText with ID: \(rtId)")

        // ⚠️ 关键：必须先 select 才能添加内容！
        sugarloaf.selectContent(richTextId: rtId)

        // 清空该 RichText 的内容
        sugarloaf.clearContent()

        // 使用链式调用构建内容
        sugarloaf
            .text("Welcome to ETerm!", color: (0.0, 1.0, 0.0, 1.0))  // 绿色
            .line()
            .text("Powered by Sugarloaf", color: (0.8, 0.8, 0.8, 1.0))  // 灰色
            .line()
            .text("$ ", color: (1.0, 1.0, 0.0, 1.0))  // 黄色提示符
            .build()

        // 提交富文本对象用于渲染
        sugarloaf.commitRichText(id: rtId)

        print("🎨 Rendering...")
        // 渲染
        sugarloaf.render()
        print("✅ Render complete")
    }

    override func layout() {
        super.layout()

        // 窗口大小改变时重新渲染
        if sugarloaf != nil {
            renderTestContent()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// SwiftUI wrapper for SugarloafNSView
struct SugarloafView: NSViewRepresentable {
    func makeNSView(context: Context) -> SugarloafNSView {
        let view = SugarloafNSView()
        return view
    }

    func updateNSView(_ nsView: SugarloafNSView, context: Context) {
        // 更新视图时的逻辑
    }
}

// MARK: - Preview
struct SugarloafView_Previews: PreviewProvider {
    static var previews: some View {
        SugarloafView()
            .frame(width: 800, height: 600)
    }
}
