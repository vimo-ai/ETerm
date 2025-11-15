//
//  ContentView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI
import SwiftTerm
import Combine

struct ContentView: View {
    var body: some View {
        TabView {
            // 完整的终端 Tab (PTY + Sugarloaf)
            TerminalView()
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
    }
}

// 翻译管理器（单例）
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
        onDismiss?()  // 通知 Container 重置
    }
}

// SwiftTerm 的 NSView wrapper
struct TerminalWrapperView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()

        // 设置字体
        if let customFont = NSFont(name: "Maple Mono NF CN", size: 13) {
            container.terminalView.font = customFont
        } else {
            container.terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        // 启动 shell
        container.terminalView.startProcess(executable: "/bin/zsh", args: ["-l", "-c", "cd ~ && exec zsh -l"])

        // 启动选择监听
        container.startMonitoringSelection()

        return container
    }

    func updateNSView(_ nsView: TerminalContainer, context: Context) {
        // 更新逻辑（暂时不需要）
    }
}

// 包装容器，监听鼠标事件 + 延迟检查
class TerminalContainer: NSView {
    let terminalView = LocalProcessTerminalView(frame: .zero)
    private var checkWorkItem: DispatchWorkItem?
    private var lastSelection: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTerminalView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTerminalView()
    }

    private func setupTerminalView() {
        terminalView.autoresizingMask = [.width, .height]
        terminalView.frame = bounds
        addSubview(terminalView)

        // 监听 Popover 关闭，重置 lastSelection
        TranslationManager.shared.onDismiss = { [weak self] in
            self?.lastSelection = ""
        }

        // 添加本地鼠标事件监听器
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            // 检查事件是否发生在 terminalView 内
            if let window = self?.window,
               let terminalView = self?.terminalView,
               terminalView.window == window {
                let locationInWindow = event.locationInWindow
                let locationInTerminal = terminalView.convert(locationInWindow, from: nil)

                if terminalView.bounds.contains(locationInTerminal) {
                    // 鼠标在终端内松开，重置延迟检查
                    self?.scheduleCheck()
                }
            }
            return event
        }
    }

    func startMonitoringSelection() {
        // 不需要额外的初始化
    }

    private func scheduleCheck() {
        // 取消之前的检查任务（关键！每次鼠标松开都重置倒计时）
        checkWorkItem?.cancel()

        // 创建新的检查任务，2 秒后执行
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkSelection()
        }

        checkWorkItem = workItem

        // 2 秒后执行（如果期间又有鼠标松开，会被上面的 cancel 取消）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func checkSelection() {
        let selectedText = terminalView.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        print("🔍 检查选择: '\(selectedText)' (上次: '\(lastSelection)')")

        guard !selectedText.isEmpty,
              selectedText != lastSelection else {
            return
        }

        lastSelection = selectedText
        print("✅ 触发翻译: '\(selectedText)'")

        DispatchQueue.main.async {
            TranslationManager.shared.showTranslation(for: selectedText)
        }
    }

    deinit {
        checkWorkItem?.cancel()
    }
}

#Preview {
    ContentView()
}
