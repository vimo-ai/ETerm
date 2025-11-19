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
    @State private var testPanels: [TestPanelData] = []
    @State private var dragInfo: String = "未开始拖拽"

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
                    panels: testPanels,
                    containerSize: geometry.size,
                    onDragInfo: { info in
                        dragInfo = info
                    }
                )
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
        testPanels = [
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "终端 1")
                    ],
                    activeTabIndex: 0
                ),
                bounds: CGRect(x: 10, y: 10, width: 780, height: 580)
            )
        ]
    }

    private func loadMultiTabsTest() {
        testPanels = [
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "终端 1"),
                        TabNode(id: UUID(), title: "终端 2"),
                        TabNode(id: UUID(), title: "终端 3"),
                        TabNode(id: UUID(), title: "终端 4"),
                    ],
                    activeTabIndex: 1
                ),
                bounds: CGRect(x: 10, y: 10, width: 780, height: 580)
            )
        ]
    }

    private func loadSplitPanelsTest() {
        testPanels = [
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "左侧 Tab 1"),
                        TabNode(id: UUID(), title: "左侧 Tab 2"),
                    ],
                    activeTabIndex: 0
                ),
                bounds: CGRect(x: 10, y: 10, width: 380, height: 580)
            ),
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "右侧 Tab 1"),
                    ],
                    activeTabIndex: 0
                ),
                bounds: CGRect(x: 400, y: 10, width: 380, height: 580)
            )
        ]
    }

    private func loadComplexLayoutTest() {
        testPanels = [
            // 左上
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "左上 1"),
                        TabNode(id: UUID(), title: "左上 2"),
                    ],
                    activeTabIndex: 0
                ),
                bounds: CGRect(x: 10, y: 300, width: 380, height: 280)
            ),
            // 左下
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "左下 1"),
                    ],
                    activeTabIndex: 0
                ),
                bounds: CGRect(x: 10, y: 10, width: 380, height: 280)
            ),
            // 右侧
            TestPanelData(
                panel: PanelNode(
                    tabs: [
                        TabNode(id: UUID(), title: "右侧 1"),
                        TabNode(id: UUID(), title: "右侧 2"),
                        TabNode(id: UUID(), title: "右侧 3"),
                    ],
                    activeTabIndex: 1
                ),
                bounds: CGRect(x: 400, y: 10, width: 380, height: 580)
            )
        ]
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

// MARK: - 测试数据

struct TestPanelData: Identifiable {
    let id = UUID()
    let panel: PanelNode
    let bounds: CGRect
}

// MARK: - Panel 容器视图（NSViewRepresentable）

struct PanelTestContainerView: NSViewRepresentable {
    let panels: [TestPanelData]
    let containerSize: CGSize
    let onDragInfo: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 移除旧的 PanelView
        nsView.subviews.forEach { $0.removeFromSuperview() }

        // 创建新的 PanelView
        let layoutKit = PanelLayoutKit()

        for panelData in panels {
            let panelView = PanelView(
                panel: panelData.panel,
                frame: panelData.bounds,
                layoutKit: layoutKit
            )

            // 设置回调
            panelView.onTabClick = { tabId in
                onDragInfo("点击 Tab: \(tabId)")
            }

            panelView.onTabDragStart = { tabId in
                onDragInfo("开始拖拽 Tab: \(tabId)")
            }

            panelView.onTabClose = { tabId in
                onDragInfo("关闭 Tab: \(tabId)")
            }

            panelView.onAddTab = {
                onDragInfo("添加新 Tab")
            }

            nsView.addSubview(panelView)
        }
    }
}

// MARK: - Preview

#Preview {
    PanelTestView()
}
