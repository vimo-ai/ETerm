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
        TabView {
            // 终端 Tab - 使用 DDD 架构
            DDDTerminalView()
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
//        window.backgroundColor = .clear

        // 设置毛玻璃效果
        // window.titlebarAppearsTransparent = true
    }

    /// 监听窗口跨屏幕移动事件
    private func setupScreenChangeNotification() {
        // 新架构中 scale 由 PanelRenderView 自动处理，不需要手动监听
    }

    /// 移除屏幕变化监听
    private func removeScreenChangeNotification() {
        // 新架构中不需要手动移除
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
