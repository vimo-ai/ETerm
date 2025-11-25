//
//  ContentView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI
import Combine

struct ContentView: View {
    var body: some View {
        RioTerminalView()
            .frame(minWidth: 800, minHeight: 600)
            .ignoresSafeArea()  // 延伸到标题栏
            .background(
                ZStack {
                    TransparentWindowBackground()
                    Color.black.opacity(0.3)
                }
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
            .onAppear {
                setupTransparentWindow()
            }
    }

    private func setupTransparentWindow() {
        guard let window = NSApplication.shared.windows.first else { return }

        // 设置窗口透明
        window.isOpaque = false
        window.backgroundColor = .clear

        // 使用 borderless 窗口（完全去掉 title bar）
        // 保留 resizable, miniaturizable, closable 功能
        window.styleMask = [.borderless, .resizable, .miniaturizable, .closable]

        // 不用全局拖动，由 PageBarHostingView 处理顶部拖动
        window.isMovableByWindowBackground = false

        // 添加圆角效果
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true
    }
}

// 翻译管理器（单例）
// 注意: 当前 Rust+Sugarloaf 方案暂未实现文本选择功能
// 此类保留用于 TranslationPopover 兼容性,将来实现文本选择时会用到
class TranslationManager: ObservableObject {
    static let shared = TranslationManager()

    @Published var selectedText: String?
    var onDismiss: (() -> Void)?

    private init() {}

    func showTranslation(for text: String) {
        guard !text.isEmpty else { return }
        selectedText = text
    }

    func dismissPopover() {
        selectedText = nil
        onDismiss?()
    }
}

// 半透明窗口背景
struct TransparentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow  // 可选: .hudWindow, .popover, .sidebar, .menu, .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
}
