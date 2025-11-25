//
//  PanelHeaderView.swift
//  ETerm
//
//  Panel Header 视图 - Tab 栏（SwiftUI 版本）
//
//  对应 Golden Layout 的 Header 组件。
//  负责：
//  - 显示所有 Tab
//  - 管理 Tab 的布局
//  - 处理 Tab 的添加/移除
//

import SwiftUI
import AppKit

// MARK: - Tab 数据模型

struct TabItem: Identifiable, Equatable {
    let id: UUID
    var title: String
}

// MARK: - PanelHeaderView (SwiftUI)

struct PanelHeaderView: View {
    // MARK: - 数据

    @Binding var tabs: [TabItem]
    @Binding var activeTabId: UUID?

    // MARK: - 回调

    var onTabClick: ((UUID) -> Void)?
    var onTabClose: ((UUID) -> Void)?
    var onTabRename: ((UUID, String) -> Void)?
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?

    // MARK: - 常量

    private static let headerHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 4) {
            // Tab 列表
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    TabItemSwiftUIView(
                        title: tab.title,
                        isActive: tab.id == activeTabId,
                        onTap: { onTabClick?(tab.id) },
                        onClose: { onTabClose?(tab.id) }
                    )
                }
            }

            Spacer()

            // 水平分割按钮
            Button(action: { onSplitHorizontal?() }) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)

            // 添加按钮
            Button(action: { onAddTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 4)
        .frame(height: Self.headerHeight)
    }

    // MARK: - 推荐高度

    static func recommendedHeight() -> CGFloat {
        return headerHeight
    }
}

// MARK: - Tab 视图（使用水墨风格）

struct TabItemSwiftUIView: View {
    let title: String
    let isActive: Bool
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let height: CGFloat = 26

    var body: some View {
        ShuimoTabView(
            title,
            isActive: isActive,
            height: height,
            onClose: onClose
        )
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - AppKit Bridge（供 DomainPanelView 使用）

/// AppKit 桥接类，用于在 NSView 层级中使用 SwiftUI PanelHeaderView
final class PanelHeaderHostingView: NSView {
    private var hostingView: NSHostingView<PanelHeaderView>?

    // 数据状态
    private var tabs: [TabItem] = []
    private var activeTabId: UUID?

    // 回调
    var onTabClick: ((UUID) -> Void)?
    var onTabClose: ((UUID) -> Void)?
    var onTabRename: ((UUID, String) -> Void)?
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        let swiftUIView = PanelHeaderView(
            tabs: Binding(
                get: { self.tabs },
                set: { self.tabs = $0 }
            ),
            activeTabId: Binding(
                get: { self.activeTabId },
                set: { self.activeTabId = $0 }
            ),
            onTabClick: onTabClick,
            onTabClose: onTabClose,
            onTabRename: onTabRename,
            onAddTab: onAddTab,
            onSplitHorizontal: onSplitHorizontal
        )

        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        hostingView = hosting
    }

    private func refreshHostingView() {
        guard let hostingView = hostingView else { return }

        let swiftUIView = PanelHeaderView(
            tabs: Binding(
                get: { self.tabs },
                set: { self.tabs = $0 }
            ),
            activeTabId: Binding(
                get: { self.activeTabId },
                set: { self.activeTabId = $0 }
            ),
            onTabClick: onTabClick,
            onTabClose: onTabClose,
            onTabRename: onTabRename,
            onAddTab: onAddTab,
            onSplitHorizontal: onSplitHorizontal
        )

        hostingView.rootView = swiftUIView
    }

    /// 设置 Tab 列表（兼容旧接口）
    func setTabs(_ newTabs: [(id: UUID, title: String)]) {
        tabs = newTabs.map { TabItem(id: $0.id, title: $0.title) }
        refreshHostingView()
    }

    /// 设置激活的 Tab（兼容旧接口）
    func setActiveTab(_ tabId: UUID) {
        activeTabId = tabId
        refreshHostingView()
    }

    /// 获取所有 Tab 的边界（用于拖拽计算，暂时返回空）
    func getTabBounds() -> [UUID: CGRect] {
        // SwiftUI 版本暂不支持精确的 Tab 边界获取
        // 如果需要拖拽功能，后续可以用 PreferenceKey 实现
        return [:]
    }

    /// 推荐高度
    static func recommendedHeight() -> CGFloat {
        return PanelHeaderView.recommendedHeight()
    }
}

// MARK: - Preview

#Preview("PanelHeaderView") {
    PanelHeaderView(
        tabs: .constant([
            TabItem(id: UUID(), title: "终端 1"),
            TabItem(id: UUID(), title: "终端 2"),
            TabItem(id: UUID(), title: "很长的标签名称")
        ]),
        activeTabId: .constant(nil)
    )
    .frame(width: 500)
    .background(Color.black.opacity(0.8))
}

#Preview("TabItemSwiftUIView") {
    VStack(spacing: 10) {
        TabItemSwiftUIView(title: "Active Tab", isActive: true)
        TabItemSwiftUIView(title: "Inactive Tab", isActive: false)
    }
    .padding(20)
    .background(Color.black.opacity(0.8))
}
