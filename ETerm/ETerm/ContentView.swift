//
//  ContentView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI
import Combine

struct ContentView: View {
    @Bindable var windowController: WindowController

    var body: some View {
        TabView {
            // 完整的终端 Tab (PTY + Sugarloaf) - 使用新的 Tab 支持版本
            TabTerminalView(controller: windowController)

                .frame(minWidth: 800, minHeight: 600)
                .tabItem {
                    Label("终端", systemImage: "terminal")
                }

            // 三个学习模块
            WordLearningView()
                .tabItem {
                    Label("单词学习", systemImage: "book")
                }

            SentenceUnderstandingView()
                .tabItem {
                    Label("句子理解", systemImage: "text.quote")
                }

            WritingAssistantView()
                .tabItem {
                    Label("写作助手", systemImage: "pencil")
                }


        }
        .frame(minWidth: 1000, minHeight: 800)
        .background(
            ZStack {
                TransparentWindowBackground()
                Color.black.opacity(0.3)  // 叠加半透明黑色,可以调整 0.0-1.0
            }
        )
        .preferredColorScheme(.dark)
        .onAppear {
            setupTransparentWindow()
            setupScreenChangeNotification()
        }
        .onDisappear {
            removeScreenChangeNotification()
        }
    }

    private func setupTransparentWindow() {
        guard let window = NSApplication.shared.windows.first else { return }

        // 设置窗口透明
        window.isOpaque = false
        window.backgroundColor = .clear

        // 设置毛玻璃效果
        window.titlebarAppearsTransparent = true
    }

    /// 监听窗口跨屏幕移动事件
    private func setupScreenChangeNotification() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak windowController] _ in
            guard let controller = windowController else { return }

            // 窗口移动到新屏幕,重新获取 scale
            if let window = NSApp.windows.first,
               let screen = window.screen {
                let newScale = screen.backingScaleFactor
                let currentSize = controller.containerSize
                controller.resizeContainer(newSize: currentSize, scale: newScale)
            }
        }
    }

    /// 移除屏幕变化监听
    private func removeScreenChangeNotification() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
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
    // Preview 环境下创建临时的 WindowController
    let controller = WindowController(
        containerSize: CGSize(width: 1000, height: 800),
        scale: 2.0
    )
    return ContentView(windowController: controller)
}
