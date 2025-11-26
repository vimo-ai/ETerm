//
//  ContentView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI
import Combine

// MARK: - Window CWD Manager

/// 临时存储新窗口的 CWD（用于窗口创建时传递）
class WindowCwdManager {
    static let shared = WindowCwdManager()

    private var pendingCwd: String?
    private let lock = NSLock()

    private init() {}

    /// 设置下一个待创建窗口的 CWD
    func setPendingCwd(_ cwd: String?) {
        lock.lock()
        defer { lock.unlock() }
        pendingCwd = cwd
    }

    /// 获取并清除待创建窗口的 CWD
    func takePendingCwd() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let cwd = pendingCwd
        pendingCwd = nil
        print("🔄 [WindowCwdManager] takePendingCwd: \(cwd ?? "nil")")
        return cwd
    }
}

struct ContentView: View {
    var body: some View {
        RioTerminalView()
            .frame(minWidth: 400, minHeight: 300)
            .ignoresSafeArea()
            .background(
                ZStack {
                    TransparentWindowBackground()
                    Color.black.opacity(0.3)
                }
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
    }
    // 窗口配置已移至 KeyableWindow 和 WindowManager
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
