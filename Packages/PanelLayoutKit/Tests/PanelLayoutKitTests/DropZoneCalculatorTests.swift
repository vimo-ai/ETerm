//
//  DropZoneCalculatorTests.swift
//  PanelLayoutKitTests
//
//  Drop Zone 计算器测试
//

import XCTest
@testable import PanelLayoutKit

final class DropZoneCalculatorTests: XCTestCase {
    var calculator: DropZoneCalculator!

    override func setUpWithError() throws {
        calculator = DropZoneCalculator()
    }

    override func tearDownWithError() throws {
        calculator = nil
    }

    // MARK: - Body Drop Zone Tests

    func testBodyDropZone_Left() throws {
        // Given: 一个 Panel 和鼠标在左侧区域
        let panel = PanelNode(
            id: UUID(),
            tabs: [
                TabNode(id: UUID(), title: "Tab 1")
            ],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 50, y: 150) // 左侧区域

        // When: 计算 Drop Zone
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then: 应该返回 Left Drop Zone
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .left)
    }

    func testBodyDropZone_Right() throws {
        // Given: 鼠标在右侧区域
        let panel = PanelNode(
            id: UUID(),
            tabs: [TabNode(id: UUID(), title: "Tab 1")],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 350, y: 150) // 右侧区域

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .right)
    }

    func testBodyDropZone_Top() throws {
        // Given: 鼠标在顶部区域
        let panel = PanelNode(
            id: UUID(),
            tabs: [TabNode(id: UUID(), title: "Tab 1")],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 200, y: 250) // 顶部区域

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .top)
    }

    func testBodyDropZone_Bottom() throws {
        // Given: 鼠标在底部区域
        let panel = PanelNode(
            id: UUID(),
            tabs: [TabNode(id: UUID(), title: "Tab 1")],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 200, y: 50) // 底部区域

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .bottom)
    }

    // MARK: - Header Drop Zone Tests

    func testHeaderDropZone_EmptyPanel() throws {
        // Given: 一个空 Panel
        let panel = PanelNode(id: UUID(), tabs: [], activeTabIndex: 0)
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 200, y: 280) // 在 Header 区域

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then: 应该返回 Header Drop Zone，插入索引为 0
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .header)
        XCTAssertEqual(dropZone?.insertIndex, 0)
    }

    func testHeaderDropZone_WithTabBounds_InsertAtBeginning() throws {
        // Given: 一个有 Tab 的 Panel
        let tab1Id = UUID()
        let tab2Id = UUID()
        let panel = PanelNode(
            id: UUID(),
            tabs: [
                TabNode(id: tab1Id, title: "Tab 1"),
                TabNode(id: tab2Id, title: "Tab 2")
            ],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let tabBounds: [UUID: CGRect] = [
            tab1Id: CGRect(x: 0, y: 270, width: 120, height: 30),
            tab2Id: CGRect(x: 124, y: 270, width: 120, height: 30)
        ]
        let mousePosition = CGPoint(x: 30, y: 280) // 在第一个 Tab 的左半部分

        // When
        let dropZone = calculator.calculateDropZoneWithTabBounds(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            tabBounds: tabBounds,
            mousePosition: mousePosition
        )

        // Then: 应该插入到索引 0
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .header)
        XCTAssertEqual(dropZone?.insertIndex, 0)
    }

    func testHeaderDropZone_WithTabBounds_InsertInMiddle() throws {
        // Given
        let tab1Id = UUID()
        let tab2Id = UUID()
        let panel = PanelNode(
            id: UUID(),
            tabs: [
                TabNode(id: tab1Id, title: "Tab 1"),
                TabNode(id: tab2Id, title: "Tab 2")
            ],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let tabBounds: [UUID: CGRect] = [
            tab1Id: CGRect(x: 0, y: 270, width: 120, height: 30),
            tab2Id: CGRect(x: 124, y: 270, width: 120, height: 30)
        ]
        let mousePosition = CGPoint(x: 100, y: 280) // 在第一个 Tab 的右半部分

        // When
        let dropZone = calculator.calculateDropZoneWithTabBounds(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            tabBounds: tabBounds,
            mousePosition: mousePosition
        )

        // Then: 应该插入到索引 1
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .header)
        XCTAssertEqual(dropZone?.insertIndex, 1)
    }

    func testHeaderDropZone_WithTabBounds_InsertAtEnd() throws {
        // Given
        let tab1Id = UUID()
        let tab2Id = UUID()
        let panel = PanelNode(
            id: UUID(),
            tabs: [
                TabNode(id: tab1Id, title: "Tab 1"),
                TabNode(id: tab2Id, title: "Tab 2")
            ],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let tabBounds: [UUID: CGRect] = [
            tab1Id: CGRect(x: 0, y: 270, width: 120, height: 30),
            tab2Id: CGRect(x: 124, y: 270, width: 120, height: 30)
        ]
        let mousePosition = CGPoint(x: 200, y: 280) // 在第二个 Tab 的右侧

        // When
        let dropZone = calculator.calculateDropZoneWithTabBounds(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            tabBounds: tabBounds,
            mousePosition: mousePosition
        )

        // Then: 应该插入到索引 2（末尾）
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .header)
        XCTAssertEqual(dropZone?.insertIndex, 2)
    }

    // MARK: - Empty Panel Tests

    func testEmptyPanel_BodyDropZone() throws {
        // Given: 一个空 Panel，鼠标在 Body 区域
        let panel = PanelNode(id: UUID(), tabs: [], activeTabIndex: 0)
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 200, y: 150) // 在 Body 区域

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then: 应该返回 Body Drop Zone
        XCTAssertNotNil(dropZone)
        XCTAssertEqual(dropZone?.type, .body)
        XCTAssertEqual(dropZone?.highlightArea, panelBounds)
    }

    // MARK: - Out of Bounds Tests

    func testMouseOutOfBounds_ReturnsNil() throws {
        // Given: 鼠标在 Panel 外部
        let panel = PanelNode(
            id: UUID(),
            tabs: [TabNode(id: UUID(), title: "Tab 1")],
            activeTabIndex: 0
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let headerBounds = CGRect(x: 0, y: 270, width: 400, height: 30)
        let mousePosition = CGPoint(x: 500, y: 150) // 在 Panel 外部

        // When
        let dropZone = calculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )

        // Then: 应该返回 nil
        XCTAssertNil(dropZone)
    }
}
