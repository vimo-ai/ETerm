//
//  PanelTestView.swift
//  ETerm
//
//  Panel UI 组件测试视图

import SwiftUI
import PanelLayoutKit

/// Panel UI 测试窗口
///
/// 用于验证 PanelView、PanelHeaderView、TabItemView 的显示效果
/// 不影响现有的终端功能
struct PanelTestView: View {
    @State private var selectedTestCase: TestCase = .singlePanel
    @State private var dragInfo: String = "未开始拖拽"

    // 布局树（主数据源）
    @State private var layoutTree: LayoutTree?
    @State private var containerSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack {
                Text("Panel UI 测试")
                    .font(.headline)

                Spacer()

                // 测试场景选择
                Picker("测试场景", selection: $selectedTestCase) {
                    ForEach(TestCase.allCases, id: \.self) { testCase in
                        Text(testCase.title).tag(testCase)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 400)

                Button("刷新") {
                    loadTestCase(selectedTestCase)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 拖拽信息
            Text(dragInfo)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(4)

            Divider()

            // Panel 显示区域
            GeometryReader { geometry in
                PanelTestContainerView(
                    layoutTree: layoutTree,
                    containerSize: geometry.size,
                    onDragInfo: { info in
                        dragInfo = info
                    },
                    onTabClick: { panelId, tabId in
                        handleTabClick(panelId: panelId, tabId: tabId)
                    },
                    onLayoutChange: { newLayoutTree in
                        layoutTree = newLayoutTree
                    }
                )
                .onChange(of: geometry.size) { _, newSize in
                    containerSize = newSize
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            loadTestCase(selectedTestCase)
        }
        .onChange(of: selectedTestCase) { _, newValue in
            loadTestCase(newValue)
        }
    }

    // MARK: - 事件处理

    private func handleTabClick(panelId: UUID, tabId: UUID) {
        // 更新布局树中对应 Panel 的 activeTabIndex
        guard let layoutTree = layoutTree else { return }

        let newLayoutTree = layoutTree.updatingPanel(panelId) { panel in
            guard let tabIndex = panel.tabs.firstIndex(where: { $0.id == tabId }) else {
                return panel
            }
            // 创建新的 PanelNode，更新 activeTabIndex
            return PanelNode(
                id: panel.id,
                tabs: panel.tabs,
                activeTabIndex: tabIndex
            )
        }

        self.layoutTree = newLayoutTree
    }

    // MARK: - 加载测试场景

    private func loadTestCase(_ testCase: TestCase) {
        switch testCase {
        case .singlePanel:
            loadSinglePanelTest()
        case .multiTabs:
            loadMultiTabsTest()
        case .splitPanels:
            loadSplitPanelsTest()
        case .complexLayout:
            loadComplexLayoutTest()
        }
    }

    private func loadSinglePanelTest() {
        // 创建 LayoutTree
        layoutTree = .panel(
            PanelNode(
                tabs: [
                    TabNode(id: UUID(), title: "终端 1")
                ],
                activeTabIndex: 0
            )
        )
    }

    private func loadMultiTabsTest() {
        // 创建 LayoutTree
        layoutTree = .panel(
            PanelNode(
                tabs: [
                    TabNode(id: UUID(), title: "终端 1"),
                    TabNode(id: UUID(), title: "终端 2"),
                    TabNode(id: UUID(), title: "终端 3"),
                    TabNode(id: UUID(), title: "终端 4"),
                ],
                activeTabIndex: 1
            )
        )
    }

    private func loadSplitPanelsTest() {
        // 创建 LayoutTree（水平分割）
        layoutTree = .split(
            direction: .horizontal,
            first: .panel(
                PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "左侧 Tab 1"),
                        TabNode(id: UUID(), title: "左侧 Tab 2"),
                    ],
                    activeTabIndex: 0
                )
            ),
            second: .panel(
                PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "右侧 Tab 1"),
                    ],
                    activeTabIndex: 0
                )
            ),
            ratio: 0.5
        )
    }

    private func loadComplexLayoutTest() {
        // 创建 LayoutTree（左侧垂直分割，右侧单个 Panel）
        // 结构：[左上 | 左下] | 右侧
        layoutTree = .split(
            direction: .horizontal,
            first: .split(
                direction: .vertical,
                first: .panel(
                    PanelNode(
                        tabs: [
                            TabNode(id: UUID(), title: "左下 1"),
                        ],
                        activeTabIndex: 0
                    )
                ),
                second: .panel(
                    PanelNode(
                        tabs: [
                            TabNode(id: UUID(), title: "左上 1"),
                            TabNode(id: UUID(), title: "左上 2"),
                        ],
                        activeTabIndex: 0
                    )
                ),
                ratio: 0.5
            ),
            second: .panel(
                PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "右侧 1"),
                        TabNode(id: UUID(), title: "右侧 2"),
                        TabNode(id: UUID(), title: "右侧 3"),
                    ],
                    activeTabIndex: 1
                )
            ),
            ratio: 0.5
        )
    }
}

// MARK: - 测试场景枚举

enum TestCase: CaseIterable {
    case singlePanel
    case multiTabs
    case splitPanels
    case complexLayout

    var title: String {
        switch self {
        case .singlePanel: return "单个 Panel"
        case .multiTabs: return "多个 Tab"
        case .splitPanels: return "分割布局"
        case .complexLayout: return "复杂布局"
        }
    }
}

// MARK: - Panel 容器视图（NSViewRepresentable）

struct PanelTestContainerView: NSViewRepresentable {
    let layoutTree: LayoutTree?
    let containerSize: CGSize
    let onDragInfo: (String) -> Void
    let onTabClick: (UUID, UUID) -> Void  // (panelId, tabId)
    let onLayoutChange: (LayoutTree) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDragInfo: onDragInfo,
            onTabClick: onTabClick,
            onLayoutChange: onLayoutChange
        )
    }

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateLayout(layoutTree, containerSize: containerSize, in: nsView)
    }

    // MARK: - Coordinator

    class Coordinator {
        let onDragInfo: (String) -> Void
        let onTabClick: (UUID, UUID) -> Void
        let onLayoutChange: (LayoutTree) -> Void

        private let layoutKit = PanelLayoutKit()
        private var panelViews: [UUID: PanelView] = [:]
        private var currentLayoutTree: LayoutTree?

        // 🎯 终端池（模拟）
        private let terminalPool = MockTerminalPool()

        // 🎯 Tab ID 到终端 ID 的映射
        private var tabTerminalMapping: [UUID: Int] = [:]

        init(
            onDragInfo: @escaping (String) -> Void,
            onTabClick: @escaping (UUID, UUID) -> Void,
            onLayoutChange: @escaping (LayoutTree) -> Void
        ) {
            self.onDragInfo = onDragInfo
            self.onTabClick = onTabClick
            self.onLayoutChange = onLayoutChange
        }

        deinit {
            print("[Coordinator] 🔄 析构，检查终端泄露...")
            terminalPool.printStatistics()
        }

        func updateLayout(_ layoutTree: LayoutTree?, containerSize: CGSize, in containerView: NSView) {
            guard let layoutTree = layoutTree else {
                // 清空所有 PanelView
                panelViews.values.forEach { $0.removeFromSuperview() }
                panelViews.removeAll()
                currentLayoutTree = nil
                return
            }

            // 🎯 确保所有 Tab 都有对应的终端（处理初始化和拖拽场景）
            ensureTerminalsForAllTabs(layoutTree)

            currentLayoutTree = layoutTree

            // 使用 BoundsCalculator 计算每个 Panel 的边界
            let panelBounds = layoutKit.calculateBounds(
                layout: layoutTree,
                containerSize: containerSize
            )

            // 获取所有 Panel
            let panels = layoutTree.allPanels()

            // 【调试】打印布局信息
            print("📐 updateLayout:")
            print("  panels:", panels.map { "Panel(\($0.id.uuidString.prefix(8)), tabs=[\($0.tabs.map { $0.title }.joined(separator: ", "))])" })
            print("  panelBounds.keys:", panelBounds.keys.map { $0.uuidString.prefix(8) })

            // 移除不再存在的 PanelView
            let panelIds = Set(panels.map { $0.id })
            let viewsToRemove = panelViews.filter { !panelIds.contains($0.key) }
            for (id, view) in viewsToRemove {
                view.removeFromSuperview()
                panelViews.removeValue(forKey: id)
            }

            // 更新或创建 PanelView
            for panel in panels {
                guard let bounds = panelBounds[panel.id] else {
                    print("❌ 找不到 Panel 的 bounds: Panel(\(panel.id.uuidString.prefix(8)), tabs=[\(panel.tabs.map { $0.title }.joined(separator: ", "))])")
                    continue
                }

                if let existingView = panelViews[panel.id] {
                    // 更新现有 PanelView
                    existingView.updatePanel(panel)
                    existingView.frame = bounds
                } else {
                    // 创建新 PanelView
                    let panelView = createPanelView(panel: panel, bounds: bounds)
                    containerView.addSubview(panelView)
                    panelViews[panel.id] = panelView
                }
            }
        }

        private func createPanelView(panel: PanelNode, bounds: CGRect) -> PanelView {
            let panelView = PanelView(
                panel: panel,
                frame: bounds,
                layoutKit: layoutKit
            )

            // 设置回调
            panelView.onTabClick = { [weak self] tabId in
                self?.onDragInfo("点击 Tab: \(tabId)")
                self?.onTabClick(panel.id, tabId)
            }

            panelView.onTabDragStart = { [weak self] tabId in
                self?.onDragInfo("开始拖拽 Tab: \(tabId)")
            }

            panelView.onTabClose = { [weak self] tabId in
                self?.handleTabClose(tabId: tabId)
            }

            panelView.onAddTab = { [weak self] in
                self?.handleAddTab(panelId: panel.id)
            }

            panelView.onDrop = { [weak self] tabId, dropZone, targetPanelId in
                return self?.handleDrop(tabId: tabId, dropZone: dropZone, targetPanelId: targetPanelId) ?? false
            }

            return panelView
        }

        /// 确保所有 Tab 都有对应的终端实例
        ///
        /// - Parameter layoutTree: 当前布局树
        private func ensureTerminalsForAllTabs(_ layoutTree: LayoutTree) {
            let allTabs = layoutTree.allTabs()
            let allTabIds = Set(allTabs.map { $0.id })

            // 1. 为新 Tab 创建终端
            for tab in allTabs {
                if tabTerminalMapping[tab.id] == nil {
                    // 这个 Tab 还没有终端，创建一个
                    let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                    tabTerminalMapping[tab.id] = terminalId

                    print("[Coordinator] 🔄 为现有 Tab 创建终端: \(tab.title) (Tab ID: \(tab.id.uuidString.prefix(8)), Terminal ID: \(terminalId))")
                }
            }

            // 2. 清理已经不存在的 Tab 的终端
            let orphanedTabIds = tabTerminalMapping.keys.filter { !allTabIds.contains($0) }
            for tabId in orphanedTabIds {
                if let terminalId = tabTerminalMapping[tabId] {
                    print("[Coordinator] 🧹 清理孤立终端: Tab ID: \(tabId.uuidString.prefix(8)), Terminal ID: \(terminalId)")
                    terminalPool.closeTerminal(terminalId)
                    tabTerminalMapping.removeValue(forKey: tabId)
                }
            }
        }

        private func handleAddTab(panelId: UUID) {
            guard let layoutTree = currentLayoutTree else {
                onDragInfo("❌ 布局树为空")
                return
            }

            // 查找目标 Panel
            guard let panel = layoutTree.findPanel(byId: panelId) else {
                onDragInfo("❌ 找不到目标 Panel")
                return
            }

            // 🎯 1. 创建终端实例
            let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")

            // 🎯 2. 创建新的 Tab 并绑定终端 ID
            let tabNumber = layoutTree.allTabs().count + 1
            let newTab = TabNode(id: UUID(), title: "终端 \(tabNumber)", rustTerminalId: terminalId)

            // 🎯 3. 保存 Tab ID 到终端 ID 的映射
            tabTerminalMapping[newTab.id] = terminalId

            // 【调试】打印添加操作详情
            print("➕ 添加 Tab 操作:")
            print("  新 Tab: \(newTab.title) (Tab ID: \(newTab.id.uuidString.prefix(8)), Terminal ID: \(terminalId))")
            print("  目标 Panel: \(panel.id.uuidString.prefix(8)), tabs=[\(panel.tabs.map { $0.title }.joined(separator: ", "))]")

            // 使用 updatingPanel 更新布局树
            let newLayoutTree = layoutTree.updatingPanel(panelId) { panel in
                return panel.addingTab(newTab)
            }

            // 【调试】打印添加后的布局树
            print("✅ 添加 Tab 后的 LayoutTree:")
            print("  allPanels:", newLayoutTree.allPanels().map {
                let tabInfo = $0.tabs.map { "(\($0.title), ID:\($0.id.uuidString.prefix(8)), Term:\($0.rustTerminalId))" }.joined(separator: ", ")
                return "Panel(\($0.id.uuidString.prefix(8)), tabs=[\(tabInfo)])"
            })

            // 更新布局树
            onDragInfo("✅ 添加 Tab: \(newTab.title) (终端 ID: \(terminalId))")
            onLayoutChange(newLayoutTree)
        }

        private func handleTabClose(tabId: UUID) {
            guard let layoutTree = currentLayoutTree else {
                onDragInfo("❌ 布局树为空")
                return
            }

            // 查找被关闭的 Tab
            guard let panel = layoutTree.findPanel(containingTab: tabId),
                  let tab = panel.tabs.first(where: { $0.id == tabId }) else {
                onDragInfo("❌ 找不到要关闭的 Tab")
                return
            }

            // 🎯 1. 销毁对应的终端实例
            if let terminalId = tabTerminalMapping[tabId] {
                terminalPool.closeTerminal(terminalId)
                tabTerminalMapping.removeValue(forKey: tabId)
            } else {
                print("⚠️ 警告：Tab \(tabId.uuidString.prefix(8)) 没有绑定的终端 ID")
            }

            // 【调试】打印关闭操作详情
            print("❌ 关闭 Tab 操作:")
            print("  Tab: \(tab.title) (Tab ID: \(tab.id.uuidString.prefix(8)), Terminal ID: \(tab.rustTerminalId))")
            print("  Panel: \(panel.id.uuidString.prefix(8)), tabs=[\(panel.tabs.map { $0.title }.joined(separator: ", "))]")

            // 调用 LayoutTree.removingTab 移除 Tab
            let newLayoutTree = layoutTree.removingTab(tabId)

            // 更新布局树
            if let newLayoutTree = newLayoutTree {
                // 【调试】打印关闭后的布局树
                print("✅ 关闭 Tab 后的 LayoutTree:")
                print("  allPanels:", newLayoutTree.allPanels().map {
                    let tabInfo = $0.tabs.map { "(\($0.title), ID:\($0.id.uuidString.prefix(8)), Term:\($0.rustTerminalId))" }.joined(separator: ", ")
                    return "Panel(\($0.id.uuidString.prefix(8)), tabs=[\(tabInfo)])"
                })

                onDragInfo("✅ 关闭 Tab: \(tab.title)")
                onLayoutChange(newLayoutTree)
            } else {
                // 🎯 所有 Tab 都被关闭了，创建一个新的默认 Tab（带终端）
                print("⚠️ 所有 Tab 已关闭，创建新的默认 Tab")

                let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                let defaultTab = TabNode(id: UUID(), title: "终端 1", rustTerminalId: terminalId)
                tabTerminalMapping[defaultTab.id] = terminalId

                let defaultPanel = PanelNode(tabs: [defaultTab], activeTabIndex: 0)
                let defaultLayout = LayoutTree.panel(defaultPanel)

                onDragInfo("⚠️ 所有 Tab 已关闭，已创建新 Tab (终端 ID: \(terminalId))")
                onLayoutChange(defaultLayout)
            }
        }

        private func handleDrop(tabId: UUID, dropZone: DropZone, targetPanelId: UUID) -> Bool {
            guard let layoutTree = currentLayoutTree else {
                onDragInfo("❌ 布局树为空")
                return false
            }

            // 查找被拖拽的 Tab
            guard let sourcePanel = layoutTree.findPanel(containingTab: tabId),
                  let tab = sourcePanel.tabs.first(where: { $0.id == tabId }) else {
                onDragInfo("❌ 找不到被拖拽的 Tab")
                return false
            }

            // 【调试】打印 Drop 操作详情
            print("🎯 Drop 操作:")
            print("  Tab: \(tab.title) (ID: \(tab.id.uuidString.prefix(8)))")
            print("  DropZone: \(dropZone.type)")
            print("  Source Panel: \(sourcePanel.id.uuidString.prefix(8)), tabs=[\(sourcePanel.tabs.map { $0.title }.joined(separator: ", "))]")
            print("  Target Panel: \(targetPanelId.uuidString.prefix(8))")

            // 调用 LayoutRestructurer 执行布局重构
            let newLayoutTree = layoutKit.handleDrop(
                layout: layoutTree,
                tab: tab,
                dropZone: dropZone,
                targetPanelId: targetPanelId
            )

            // 【调试】打印 Drop 成功后的布局树
            print("✅ Drop 成功后的 LayoutTree:")
            print("  allPanels:", newLayoutTree.allPanels().map {
                let tabInfo = $0.tabs.map { "(\($0.title), ID:\($0.id.uuidString.prefix(8)))" }.joined(separator: ", ")
                return "Panel(\($0.id.uuidString.prefix(8)), tabs=[\(tabInfo)])"
            })

            // 更新布局树
            onDragInfo("✅ Drop 成功: \(tab.title) → \(dropZone.type)")
            onLayoutChange(newLayoutTree)

            return true
        }
    }
}

// MARK: - Preview

#Preview {
    PanelTestView()
}
