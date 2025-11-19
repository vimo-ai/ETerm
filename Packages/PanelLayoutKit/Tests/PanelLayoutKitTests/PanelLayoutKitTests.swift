//
//  PanelLayoutKitTests.swift
//  PanelLayoutKitTests
//
//  PanelLayoutKit 测试套件
//

import Testing
import Foundation
import CoreGraphics
@testable import PanelLayoutKit

// MARK: - 数据结构测试

@Test("创建 TabNode")
func testTabNodeCreation() {
    let tab = TabNode(title: "Terminal 1")
    #expect(tab.title == "Terminal 1")
}

@Test("创建 PanelNode")
func testPanelNodeCreation() {
    let tab1 = TabNode(title: "Tab 1")
    let tab2 = TabNode(title: "Tab 2")
    let panel = PanelNode(tabs: [tab1, tab2], activeTabIndex: 0)

    #expect(panel.tabs.count == 2)
    #expect(panel.activeTabIndex == 0)
    #expect(panel.activeTab?.id == tab1.id)
}

@Test("PanelNode 添加 Tab")
func testPanelNodeAddTab() {
    let tab1 = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)

    let tab2 = TabNode(title: "Tab 2")
    let newPanel = panel.addingTab(tab2)

    #expect(newPanel.tabs.count == 2)
    #expect(newPanel.activeTabIndex == 1)  // 新添加的 Tab 被激活
}

@Test("PanelNode 移除 Tab")
func testPanelNodeRemoveTab() {
    let tab1 = TabNode(title: "Tab 1")
    let tab2 = TabNode(title: "Tab 2")
    let panel = PanelNode(tabs: [tab1, tab2], activeTabIndex: 0)

    let newPanel = panel.removingTab(tab1.id)
    #expect(newPanel != nil)
    #expect(newPanel?.tabs.count == 1)
    #expect(newPanel?.activeTab?.id == tab2.id)
}

@Test("PanelNode 移除最后一个 Tab 返回 nil")
func testPanelNodeRemoveLastTab() {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)

    let newPanel = panel.removingTab(tab.id)
    #expect(newPanel == nil)
}

// MARK: - LayoutTree 测试

@Test("创建单个 Panel 的 LayoutTree")
func testLayoutTreeSinglePanel() {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    #expect(layout.allPanels().count == 1)
    #expect(layout.allTabs().count == 1)
}

@Test("创建分割的 LayoutTree")
func testLayoutTreeSplit() {
    let tab1 = TabNode(title: "Tab 1")
    let panel1 = PanelNode(tabs: [tab1], activeTabIndex: 0)

    let tab2 = TabNode(title: "Tab 2")
    let panel2 = PanelNode(tabs: [tab2], activeTabIndex: 0)

    let layout = LayoutTree.split(
        direction: .horizontal,
        first: .panel(panel1),
        second: .panel(panel2),
        ratio: 0.5
    )

    #expect(layout.allPanels().count == 2)
    #expect(layout.allTabs().count == 2)
}

@Test("LayoutTree 查找 Panel")
func testLayoutTreeFindPanel() {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let foundPanel = layout.findPanel(byId: panel.id)
    #expect(foundPanel != nil)
    #expect(foundPanel?.id == panel.id)
}

@Test("LayoutTree 查找包含 Tab 的 Panel")
func testLayoutTreeFindPanelContainingTab() {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let foundPanel = layout.findPanel(containingTab: tab.id)
    #expect(foundPanel != nil)
    #expect(foundPanel?.id == panel.id)
}

@Test("LayoutTree 移除 Tab")
func testLayoutTreeRemoveTab() {
    let tab1 = TabNode(title: "Tab 1")
    let tab2 = TabNode(title: "Tab 2")
    let panel = PanelNode(tabs: [tab1, tab2], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let newLayout = layout.removingTab(tab1.id)
    #expect(newLayout != nil)
    #expect(newLayout?.allTabs().count == 1)
}

@Test("LayoutTree 移除最后一个 Tab 返回 nil")
func testLayoutTreeRemoveLastTab() {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let newLayout = layout.removingTab(tab.id)
    #expect(newLayout == nil)
}

// MARK: - BoundsCalculator 测试

@Test("计算单个 Panel 的边界")
func testBoundsCalculatorSinglePanel() {
    let calculator = BoundsCalculator()
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let containerSize = CGSize(width: 800, height: 600)
    let bounds = calculator.calculatePanelBounds(layout: layout, containerSize: containerSize)

    #expect(bounds.count == 1)
    let panelBounds = bounds[panel.id]
    #expect(panelBounds != nil)
    #expect(panelBounds?.width == 800)
    #expect(panelBounds?.height == 600)
}

@Test("计算水平分割的边界")
func testBoundsCalculatorHorizontalSplit() {
    let calculator = BoundsCalculator()

    let tab1 = TabNode(title: "Tab 1")
    let panel1 = PanelNode(tabs: [tab1], activeTabIndex: 0)

    let tab2 = TabNode(title: "Tab 2")
    let panel2 = PanelNode(tabs: [tab2], activeTabIndex: 0)

    let layout = LayoutTree.split(
        direction: .horizontal,
        first: .panel(panel1),
        second: .panel(panel2),
        ratio: 0.5
    )

    let containerSize = CGSize(width: 800, height: 600)
    let bounds = calculator.calculatePanelBounds(layout: layout, containerSize: containerSize)

    #expect(bounds.count == 2)

    let bounds1 = bounds[panel1.id]
    let bounds2 = bounds[panel2.id]

    #expect(bounds1 != nil)
    #expect(bounds2 != nil)

    // 水平分割：左右各占一半
    #expect(bounds1?.width == 400)
    #expect(bounds1?.height == 600)
    #expect(bounds2?.width == 400)
    #expect(bounds2?.height == 600)

    // 检查位置
    #expect(bounds1?.origin.x == 0)
    #expect(bounds2?.origin.x == 400)
}

@Test("计算垂直分割的边界")
func testBoundsCalculatorVerticalSplit() {
    let calculator = BoundsCalculator()

    let tab1 = TabNode(title: "Tab 1")
    let panel1 = PanelNode(tabs: [tab1], activeTabIndex: 0)

    let tab2 = TabNode(title: "Tab 2")
    let panel2 = PanelNode(tabs: [tab2], activeTabIndex: 0)

    let layout = LayoutTree.split(
        direction: .vertical,
        first: .panel(panel1),
        second: .panel(panel2),
        ratio: 0.5
    )

    let containerSize = CGSize(width: 800, height: 600)
    let bounds = calculator.calculatePanelBounds(layout: layout, containerSize: containerSize)

    #expect(bounds.count == 2)

    let bounds1 = bounds[panel1.id]
    let bounds2 = bounds[panel2.id]

    #expect(bounds1 != nil)
    #expect(bounds2 != nil)

    // 垂直分割：上下各占一半
    #expect(bounds1?.width == 800)
    #expect(bounds1?.height == 300)
    #expect(bounds2?.width == 800)
    #expect(bounds2?.height == 300)

    // 检查位置（macOS 坐标系：first 在下方）
    #expect(bounds1?.origin.y == 0)
    #expect(bounds2?.origin.y == 300)
}

// MARK: - DropZoneCalculator 测试

@Test("计算空 Panel 的 Drop Zone")
func testDropZoneCalculatorEmptyPanel() {
    let calculator = DropZoneCalculator()
    let panel = PanelNode(tabs: [], activeTabIndex: 0)
    let panelBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let headerBounds = CGRect(x: 0, y: 600, width: 800, height: 30)
    let mousePosition = CGPoint(x: 400, y: 300)

    let dropZone = calculator.calculateDropZone(
        panel: panel,
        panelBounds: panelBounds,
        headerBounds: headerBounds,
        mousePosition: mousePosition
    )

    #expect(dropZone != nil)
    #expect(dropZone?.type == .body)
}

@Test("计算 Header Drop Zone")
func testDropZoneCalculatorHeader() {
    let calculator = DropZoneCalculator()
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let panelBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let headerBounds = CGRect(x: 0, y: 600, width: 800, height: 30)
    let mousePosition = CGPoint(x: 400, y: 615)  // 在 Header 中

    let dropZone = calculator.calculateDropZone(
        panel: panel,
        panelBounds: panelBounds,
        headerBounds: headerBounds,
        mousePosition: mousePosition
    )

    #expect(dropZone != nil)
    #expect(dropZone?.type == .header)
}

@Test("计算左侧 Drop Zone")
func testDropZoneCalculatorLeft() {
    let calculator = DropZoneCalculator()
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let panelBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let headerBounds = CGRect(x: 0, y: 600, width: 800, height: 30)
    let mousePosition = CGPoint(x: 100, y: 300)  // 左侧 25% 内

    let dropZone = calculator.calculateDropZone(
        panel: panel,
        panelBounds: panelBounds,
        headerBounds: headerBounds,
        mousePosition: mousePosition
    )

    #expect(dropZone != nil)
    #expect(dropZone?.type == .left)
}

@Test("计算右侧 Drop Zone")
func testDropZoneCalculatorRight() {
    let calculator = DropZoneCalculator()
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let panelBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let headerBounds = CGRect(x: 0, y: 600, width: 800, height: 30)
    let mousePosition = CGPoint(x: 700, y: 300)  // 右侧 25% 内

    let dropZone = calculator.calculateDropZone(
        panel: panel,
        panelBounds: panelBounds,
        headerBounds: headerBounds,
        mousePosition: mousePosition
    )

    #expect(dropZone != nil)
    #expect(dropZone?.type == .right)
}

// MARK: - LayoutRestructurer 测试

@Test("Header Drop：添加 Tab 到 Panel")
func testLayoutRestructurerHeaderDrop() {
    let restructurer = LayoutRestructurer()

    let tab1 = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let tab2 = TabNode(title: "Tab 2")
    let dropZone = DropZone(type: .header, highlightArea: .zero, insertIndex: 1)

    let newLayout = restructurer.handleDrop(
        layout: layout,
        tab: tab2,
        dropZone: dropZone,
        targetPanelId: panel.id
    )

    let newPanel = newLayout.findPanel(byId: panel.id)
    #expect(newPanel != nil)
    #expect(newPanel?.tabs.count == 2)
}

@Test("Body Drop：添加 Tab 到空 Panel")
func testLayoutRestructurerBodyDrop() {
    let restructurer = LayoutRestructurer()

    let panel = PanelNode(tabs: [], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let tab = TabNode(title: "Tab 1")
    let dropZone = DropZone(type: .body, highlightArea: .zero)

    let newLayout = restructurer.handleDrop(
        layout: layout,
        tab: tab,
        dropZone: dropZone,
        targetPanelId: panel.id
    )

    let newPanel = newLayout.findPanel(byId: panel.id)
    #expect(newPanel != nil)
    #expect(newPanel?.tabs.count == 1)
}

@Test("Left Drop：在左侧创建新 Panel")
func testLayoutRestructurerLeftDrop() {
    let restructurer = LayoutRestructurer()

    let tab1 = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let tab2 = TabNode(title: "Tab 2")
    let dropZone = DropZone(type: .left, highlightArea: .zero)

    let newLayout = restructurer.handleDrop(
        layout: layout,
        tab: tab2,
        dropZone: dropZone,
        targetPanelId: panel.id
    )

    // 应该创建一个水平分割
    #expect(newLayout.allPanels().count == 2)
    #expect(newLayout.allTabs().count == 2)
}

@Test("Right Drop：在右侧创建新 Panel")
func testLayoutRestructurerRightDrop() {
    let restructurer = LayoutRestructurer()

    let tab1 = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    let tab2 = TabNode(title: "Tab 2")
    let dropZone = DropZone(type: .right, highlightArea: .zero)

    let newLayout = restructurer.handleDrop(
        layout: layout,
        tab: tab2,
        dropZone: dropZone,
        targetPanelId: panel.id
    )

    // 应该创建一个水平分割
    #expect(newLayout.allPanels().count == 2)
    #expect(newLayout.allTabs().count == 2)
}

// MARK: - DragSession 测试

@Test("创建 DragSession")
func testDragSessionCreation() {
    let session = DragSession()
    #expect(session.state == .idle)
}

@Test("开始拖拽")
func testDragSessionStart() {
    let session = DragSession()
    let tab = TabNode(title: "Tab 1")
    let panelId = UUID()

    session.startDrag(tab: tab, sourcePanelId: panelId)
    #expect(session.state != .idle)
}

@Test("结束拖拽")
func testDragSessionEnd() {
    let session = DragSession()
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    session.startDrag(tab: tab, sourcePanelId: panel.id)
    // 更新位置到左侧 Drop Zone（x: 100 在 0-25% 范围内）
    session.updatePosition(
        CGPoint(x: 100, y: 300),
        layout: layout,
        containerSize: CGSize(width: 800, height: 600)
    )

    let result = session.endDrag()
    #expect(result != nil)
}

// MARK: - 集成测试

@Test("完整的拖拽流程")
func testFullDragFlow() {
    let kit = PanelLayoutKit()

    // 创建初始布局：单个 Panel，包含一个 Tab
    let tab1 = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    // 计算边界
    let containerSize = CGSize(width: 800, height: 600)
    let bounds = kit.calculateBounds(layout: layout, containerSize: containerSize)

    #expect(bounds.count == 1)

    // 模拟拖拽：将 Tab 拖到右侧
    let tab2 = TabNode(title: "Tab 2")
    let dropZone = DropZone(type: .right, highlightArea: .zero)

    let newLayout = kit.handleDrop(
        layout: layout,
        tab: tab2,
        dropZone: dropZone,
        targetPanelId: panel.id
    )

    // 验证结果：应该有两个 Panel
    #expect(newLayout.allPanels().count == 2)
    #expect(newLayout.allTabs().count == 2)
}

@Test("序列化和反序列化 LayoutTree")
func testLayoutTreeSerialization() throws {
    let tab = TabNode(title: "Tab 1")
    let panel = PanelNode(tabs: [tab], activeTabIndex: 0)
    let layout = LayoutTree.panel(panel)

    // 编码
    let encoder = JSONEncoder()
    let data = try encoder.encode(layout)

    // 解码
    let decoder = JSONDecoder()
    let decodedLayout = try decoder.decode(LayoutTree.self, from: data)

    // 验证
    #expect(decodedLayout == layout)
}
