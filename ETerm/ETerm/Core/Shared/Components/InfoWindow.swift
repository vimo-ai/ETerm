//
//  InfoWindow.swift
//  ETerm
//
//  全局信息窗口 - 显示多个插件内容

import SwiftUI
import AppKit
import Combine

/// 全局信息窗口
final class InfoWindow: NSWindow {

    private weak var registry: InfoWindowRegistry?
    private var hostingView: NSHostingView<InfoWindowContentView>?
    private var cancellables = Set<AnyCancellable>()

    init(registry: InfoWindowRegistry) {
        self.registry = registry

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
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

        // 跟随当前 Space
        collectionBehavior = [.moveToActiveSpace]

        // 关闭时隐藏而不是释放
        isReleasedWhenClosed = false

        // 最小尺寸
        minSize = NSSize(width: 400, height: 200)
    }

    private func setupContent() {
        guard let registry = registry else { return }

        // 毛玻璃背景作为 contentView
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        // SwiftUI 内容
        let content = InfoWindowContentView(registry: registry)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        self.contentView = visualEffect
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
    override var canBecomeMain: Bool { true }
}

// MARK: - InfoWindow Content View

struct InfoWindowContentView: View {
    @ObservedObject var registry: InfoWindowRegistry

    var body: some View {
        Group {
            if visibleContents.isEmpty {
                emptyStateView
            } else {
                contentListView
            }
        }
        .frame(minWidth: 400, minHeight: 200)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("暂无内容")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content List

    private var contentListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(visibleContents) { content in
                    InfoContentCard(
                        content: content,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                registry.hideContent(id: content.id)
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(16)
        }
    }

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

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            cardHeader

            // 分隔线
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            // 内容区
            content.viewProvider()
                .padding(12)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(isHovering ? 0.15 : 0.08), radius: isHovering ? 8 : 4, y: 2)
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(content.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            CloseButton(action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        Color(nsColor: .controlBackgroundColor).opacity(0.6)
    }
}

// MARK: - Close Button

private struct CloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? .white : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(isHovering ? Color.secondary : Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .help("关闭")
    }
}

