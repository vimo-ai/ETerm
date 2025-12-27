//
//  InfoWindow.swift
//  ETerm
//
//  全局信息窗口 - 显示多个插件内容

import SwiftUI
import AppKit
import Combine

/// 全局信息窗口
final class InfoWindow: NSPanel {

    private weak var registry: InfoWindowRegistry?
    private var hostingView: NSHostingView<InfoWindowContentView>?
    private var cancellables = Set<AnyCancellable>()

    init(registry: InfoWindowRegistry) {
        self.registry = registry

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )

        setupWindow()
        setupContent()
        setupObservers()
        centerWindow()
    }

    // MARK: - Setup

    private func setupWindow() {
        title = "信息面板"
        level = .floating
        isOpaque = false
        backgroundColor = NSColor.windowBackgroundColor

        // 允许在所有 Space 显示
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 应用失去焦点时不自动隐藏
        hidesOnDeactivate = false

        // 关闭时隐藏而不是释放
        isReleasedWhenClosed = false

        // 最小尺寸
        minSize = NSSize(width: 400, height: 200)
    }

    private func setupContent() {
        guard let registry = registry else { return }

        let content = InfoWindowContentView(registry: registry)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
        self.hostingView = hosting
    }

    private func setupObservers() {
        guard let registry = registry else { return }

        // 监听可见内容变化
        registry.$visibleContentIds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                // 如果没有内容，自动关闭窗口
                if ids.isEmpty {
                    self?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // 监听目标位置变化
        registry.$targetRect
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rect in
                if rect != .zero {
                    self?.positionNear(rect: rect)
                }
            }
            .store(in: &cancellables)
    }

    private func centerWindow() {
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = frame
            let x = screenRect.midX - windowRect.width / 2
            let y = screenRect.midY - windowRect.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// 定位窗口在选中文本上方
    private func positionNear(rect: NSRect) {
        guard let screen = NSScreen.main else {
            centerWindow()
            return
        }

        let screenRect = screen.visibleFrame
        let windowRect = frame
        let margin: CGFloat = 10

        // X: 居中于选中文本，但不超出屏幕
        var x = rect.midX - windowRect.width / 2
        x = max(screenRect.minX + margin, min(x, screenRect.maxX - windowRect.width - margin))

        // Y: 优先显示在选中文本上方
        var y = rect.maxY + margin

        // 如果上方空间不够，显示在下方
        if y + windowRect.height > screenRect.maxY {
            y = rect.minY - windowRect.height - margin
        }

        // 确保不超出屏幕底部
        y = max(screenRect.minY + margin, y)

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Window Behavior

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // 关闭时只隐藏窗口，不清空内容列表
    // 内容由插件通过 hideContent() 管理
    override func close() {
        super.close()
    }
}

// MARK: - InfoWindow Content View

struct InfoWindowContentView: View {
    @ObservedObject var registry: InfoWindowRegistry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(visibleContents) { content in
                    InfoContentCard(
                        content: content,
                        onClose: {
                            registry.hideContent(id: content.id)
                        }
                    )
                }
            }
            .padding(16)
        }
        .frame(minWidth: 400, minHeight: 200)
    }

    /// 获取可见的内容项列表
    private var visibleContents: [InfoContent] {
        registry.visibleContentIds.compactMap { id in
            registry.registeredContents[id]
        }
    }
}

// MARK: - InfoContent Card

struct InfoContentCard: View {
    let content: InfoContent
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题栏
            HStack {
                Text(content.title)
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 内容
            content.viewProvider()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
