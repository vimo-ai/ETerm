//
//  LayoutCalculatorTests.swift
//  ETermTests
//
//  布局计算器测试 - 验证坐标系和分割逻辑

import XCTest
@testable import ETerm

final class LayoutCalculatorTests: XCTestCase {

    var calculator: BinaryTreeLayoutCalculator!

    override func setUp() {
        super.setUp()
        calculator = BinaryTreeLayoutCalculator()
    }

    // MARK: - EdgeDirection Tests

    func testEdgeDirectionSplitDirection() {
        // 验证 EdgeDirection 到 SplitDirection 的转换
        XCTAssertEqual(EdgeDirection.top.splitDirection, .vertical)
        XCTAssertEqual(EdgeDirection.bottom.splitDirection, .vertical)
        XCTAssertEqual(EdgeDirection.left.splitDirection, .horizontal)
        XCTAssertEqual(EdgeDirection.right.splitDirection, .horizontal)
    }

    func testEdgeDirectionExistingPanelIsFirst() {
        // 当前逻辑：top/left → first, bottom/right → second
        XCTAssertTrue(EdgeDirection.top.existingPanelIsFirst, "top 应该放在 first")
        XCTAssertTrue(EdgeDirection.left.existingPanelIsFirst, "left 应该放在 first")
        XCTAssertFalse(EdgeDirection.bottom.existingPanelIsFirst, "bottom 应该放在 second")
        XCTAssertFalse(EdgeDirection.right.existingPanelIsFirst, "right 应该放在 second")
    }

    // MARK: - Vertical Split Coordinate Tests

    func testVerticalSplitBoundsCoordinates() {
        // 测试垂直分割后的坐标
        // 容器：100x100，从 (0, 0) 开始
        let panelA = UUID()
        let panelB = UUID()

        let layout = PanelLayout.split(
            direction: .vertical,
            first: .leaf(panelId: panelA),
            second: .leaf(panelId: panelB),
            ratio: 0.5
        )

        let bounds = calculator.calculatePanelBounds(
            layout: layout,
            containerSize: CGSize(width: 100, height: 100)
        )

        guard let boundsA = bounds[panelA], let boundsB = bounds[panelB] else {
            XCTFail("无法获取 Panel bounds")
            return
        }

        // 打印实际坐标，帮助理解坐标系
        print("Panel A (first): y=\(boundsA.y), height=\(boundsA.height)")
        print("Panel B (second): y=\(boundsB.y), height=\(boundsB.height)")

        // 验证：first 的 y 应该更小（在上方或下方取决于坐标系）
        XCTAssertEqual(boundsA.y, 0, "first panel 应该从 y=0 开始")
        XCTAssertEqual(boundsB.y, 50, "second panel 应该从 y=50 开始")

        // 关键问题：y=0 是屏幕上方还是下方？
        // 如果是翻转坐标系（Y 向下）：y=0 在上方，y=50 在下方
        // 如果是原生坐标系（Y 向上）：y=0 在下方，y=50 在上方
    }

    // MARK: - Split Layout with EdgeDirection Tests

    func testCalculateSplitLayoutWithEdge_Top() {
        // 测试拖到上边缘时的布局
        let targetPanel = UUID()
        let newPanel = UUID()

        let currentLayout = PanelLayout.leaf(panelId: targetPanel)

        let newLayout = calculator.calculateSplitLayout(
            currentLayout: currentLayout,
            targetPanelId: targetPanel,
            newPanelId: newPanel,
            edge: .top
        )

        // 验证布局结构
        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .vertical)

            // 根据当前逻辑：top → existingPanelIsFirst = true
            // 所以 newPanel 应该在 first
            if case .leaf(let firstId) = first {
                XCTAssertEqual(firstId, newPanel, "拖到 top 边缘时，新 Panel 应该在 first（期望在上方显示）")
            } else {
                XCTFail("first 应该是 leaf")
            }

            if case .leaf(let secondId) = second {
                XCTAssertEqual(secondId, targetPanel, "目标 Panel 应该在 second")
            } else {
                XCTFail("second 应该是 leaf")
            }
        } else {
            XCTFail("应该生成 split 布局")
        }
    }

    func testCalculateSplitLayoutWithEdge_Bottom() {
        // 测试拖到下边缘时的布局
        let targetPanel = UUID()
        let newPanel = UUID()

        let currentLayout = PanelLayout.leaf(panelId: targetPanel)

        let newLayout = calculator.calculateSplitLayout(
            currentLayout: currentLayout,
            targetPanelId: targetPanel,
            newPanelId: newPanel,
            edge: .bottom
        )

        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .vertical)

            // 根据当前逻辑：bottom → existingPanelIsFirst = false
            // 所以 newPanel 应该在 second
            if case .leaf(let firstId) = first {
                XCTAssertEqual(firstId, targetPanel, "目标 Panel 应该在 first")
            }

            if case .leaf(let secondId) = second {
                XCTAssertEqual(secondId, newPanel, "拖到 bottom 边缘时，新 Panel 应该在 second（期望在下方显示）")
            }
        } else {
            XCTFail("应该生成 split 布局")
        }
    }

    func testCalculateSplitLayoutWithEdge_Left() {
        let targetPanel = UUID()
        let newPanel = UUID()

        let currentLayout = PanelLayout.leaf(panelId: targetPanel)

        let newLayout = calculator.calculateSplitLayout(
            currentLayout: currentLayout,
            targetPanelId: targetPanel,
            newPanelId: newPanel,
            edge: .left
        )

        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .horizontal)

            // left → existingPanelIsFirst = true → newPanel 在 first
            if case .leaf(let firstId) = first {
                XCTAssertEqual(firstId, newPanel, "拖到 left 边缘时，新 Panel 应该在 first（左侧）")
            }

            if case .leaf(let secondId) = second {
                XCTAssertEqual(secondId, targetPanel, "目标 Panel 应该在 second（右侧）")
            }
        }
    }

    func testCalculateSplitLayoutWithEdge_Right() {
        let targetPanel = UUID()
        let newPanel = UUID()

        let currentLayout = PanelLayout.leaf(panelId: targetPanel)

        let newLayout = calculator.calculateSplitLayout(
            currentLayout: currentLayout,
            targetPanelId: targetPanel,
            newPanelId: newPanel,
            edge: .right
        )

        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .horizontal)

            // right → existingPanelIsFirst = false → newPanel 在 second
            if case .leaf(let firstId) = first {
                XCTAssertEqual(firstId, targetPanel, "目标 Panel 应该在 first（左侧）")
            }

            if case .leaf(let secondId) = second {
                XCTAssertEqual(secondId, newPanel, "拖到 right 边缘时，新 Panel 应该在 second（右侧）")
            }
        }
    }

    // MARK: - Panel Move (上下换位置) Tests

    /// 测试：将 Panel A 移动到 Panel B 的上边缘
    /// 初始状态：A 在下，B 在上（vertical split）
    /// 操作：拖 A 到 B 的上边缘
    /// 期望结果：A 在上，B 在下
    func testMovePanelToTop_SwapsPosition() {
        let panelA = UUID()
        let panelB = UUID()

        // 初始布局：vertical split, A 在 first (下), B 在 second (上)
        // 注释说 "first 在下方，second 在上方"
        let initialLayout = PanelLayout.split(
            direction: .vertical,
            first: .leaf(panelId: panelA),
            second: .leaf(panelId: panelB),
            ratio: 0.5
        )

        // 从布局中移除 panelA
        let layoutWithoutA = PanelLayout.leaf(panelId: panelB)

        // 将 panelA 移动到 panelB 的上边缘
        let newLayout = calculator.calculateSplitLayoutWithExistingPanel(
            currentLayout: layoutWithoutA,
            targetPanelId: panelB,
            existingPanelId: panelA,
            edge: .top
        )

        // 验证新布局
        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .vertical, "应该是垂直分割")

            // 关键验证：拖到 top 边缘后，panelA 应该在哪里？
            // 当前逻辑：top → existingPanelIsFirst = true → panelA 在 first
            if case .leaf(let firstId) = first,
               case .leaf(let secondId) = second {
                print("拖到 top 边缘后：")
                print("  first (下方?): \(firstId == panelA ? "A" : "B")")
                print("  second (上方?): \(secondId == panelA ? "A" : "B")")

                // 如果注释正确（first=下方，second=上方）
                // 且用户期望 A 出现在上方
                // 那么 A 应该在 second
                // 但当前逻辑是 A 在 first

                // 这个断言反映当前逻辑，根据实际测试结果调整
                XCTAssertEqual(firstId, panelA, "当前逻辑：拖到 top 时，panelA 放在 first")
                XCTAssertEqual(secondId, panelB, "当前逻辑：panelB 放在 second")
            }
        } else {
            XCTFail("应该生成 split 布局")
        }
    }

    /// 测试：将 Panel A 移动到 Panel B 的下边缘
    func testMovePanelToBottom_SwapsPosition() {
        let panelA = UUID()
        let panelB = UUID()

        let layoutWithoutA = PanelLayout.leaf(panelId: panelB)

        let newLayout = calculator.calculateSplitLayoutWithExistingPanel(
            currentLayout: layoutWithoutA,
            targetPanelId: panelB,
            existingPanelId: panelA,
            edge: .bottom
        )

        if case .split(let direction, let first, let second, _) = newLayout {
            XCTAssertEqual(direction, .vertical)

            if case .leaf(let firstId) = first,
               case .leaf(let secondId) = second {
                print("拖到 bottom 边缘后：")
                print("  first (下方?): \(firstId == panelA ? "A" : "B")")
                print("  second (上方?): \(secondId == panelA ? "A" : "B")")

                // 当前逻辑：bottom → existingPanelIsFirst = false → panelA 在 second
                XCTAssertEqual(firstId, panelB, "当前逻辑：panelB 放在 first")
                XCTAssertEqual(secondId, panelA, "当前逻辑：拖到 bottom 时，panelA 放在 second")
            }
        }
    }

    /// 测试：验证坐标系 - first/second 对应屏幕上的哪个位置
    func testCoordinateSystem_FirstSecondMapping() {
        let panelA = UUID()
        let panelB = UUID()

        // A 在 first, B 在 second
        let layout = PanelLayout.split(
            direction: .vertical,
            first: .leaf(panelId: panelA),
            second: .leaf(panelId: panelB),
            ratio: 0.5
        )

        let bounds = calculator.calculatePanelBounds(
            layout: layout,
            containerSize: CGSize(width: 100, height: 100)
        )

        let boundsA = bounds[panelA]!
        let boundsB = bounds[panelB]!

        print("=== 坐标系映射验证 ===")
        print("Panel A (first): y=\(boundsA.y)")
        print("Panel B (second): y=\(boundsB.y)")

        // 验证坐标
        XCTAssertEqual(boundsA.y, 0, "first 从 y=0 开始")
        XCTAssertEqual(boundsB.y, 50, "second 从 y=50 开始")

        // 关键问题：在屏幕上，y=0 是上方还是下方？
        // 如果 y=0 在上方（翻转坐标系）：A 在上，B 在下
        // 如果 y=0 在下方（原生坐标系）：A 在下，B 在上
        //
        // 根据代码注释 "first 在下方，second 在上方"，
        // 说明使用的是原生坐标系（y=0 在下方）
        //
        // 但如果实际视觉效果相反，说明注释是错的！
        print("如果注释正确 (y=0 在下)：A 在下，B 在上")
        print("如果注释错误 (y=0 在上)：A 在上，B 在下")
        print("========================")
    }

    // MARK: - Visual Verification Helper

    func testPrintCoordinateSystemInfo() {
        // 这个测试只是打印信息，帮助理解坐标系
        let panelA = UUID()
        let panelB = UUID()

        let layout = PanelLayout.split(
            direction: .vertical,
            first: .leaf(panelId: panelA),
            second: .leaf(panelId: panelB),
            ratio: 0.5
        )

        let bounds = calculator.calculatePanelBounds(
            layout: layout,
            containerSize: CGSize(width: 100, height: 100)
        )

        print("=== 坐标系验证 ===")
        print("容器大小: 100x100")
        print("Panel A (first): \(bounds[panelA]!)")
        print("Panel B (second): \(bounds[panelB]!)")
        print("")
        print("如果 y=0 在屏幕上方（翻转坐标系）：")
        print("  - Panel A (y=0) 显示在上方")
        print("  - Panel B (y=50) 显示在下方")
        print("")
        print("如果 y=0 在屏幕下方（原生坐标系）：")
        print("  - Panel A (y=0) 显示在下方")
        print("  - Panel B (y=50) 显示在上方")
        print("===================")

        // 这个测试总是通过，只是为了打印信息
        XCTAssertTrue(true)
    }
}
