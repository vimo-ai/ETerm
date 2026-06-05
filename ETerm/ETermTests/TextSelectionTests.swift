//
//  TextSelectionTests.swift
//  ETermTests
//
//  选区半格 side 契约测试 —— 锁定 A2 step2 的行为约束：
//  - 单击（未拖拽）选中一整格（不回归为空选区）
//  - 拖拽时锚点（按下的那格）始终被包含，不论拖拽方向
//  - 活动端（终点）跟随光标半格 side，得到精确边界
//  实际"边界格是否包含"由 Rust resolved_range 解析并单独测试；这里只验证
//  Swift 侧喂给 FFI 的 side 是否正确。

import XCTest
@testable import ETerm

final class TextSelectionTests: XCTestCase {

    // MARK: - 单击 = 整格

    func testSingleClickSelectsFullCell() {
        let sel = TextSelection.single(absoluteRow: 0, col: 5)
        // 同一格、两端 .left/.right → 解析为该整格（非空）
        XCTAssertEqual(sel.startAbsoluteRow, 0)
        XCTAssertEqual(sel.startCol, 5)
        XCTAssertEqual(sel.endAbsoluteRow, 0)
        XCTAssertEqual(sel.endCol, 5)
        XCTAssertEqual(sel.startSide, .left)
        XCTAssertEqual(sel.endSide, .right)
    }

    // MARK: - 向右拖：锚点（起点）恒含，终点跟光标半格

    func testDragRightEndOnLeftHalfExcludesEndCell() {
        // 按下 col5，拖到 col10 的左半（.left）
        let sel = TextSelection.single(absoluteRow: 0, col: 5)
            .updateEnd(absoluteRow: 0, col: 10, side: .left)
        XCTAssertEqual(sel.startSide, .left)   // 锚点 col5 作为起端 → 含
        XCTAssertEqual(sel.endSide, .left)     // col10 左半 → 末端 .left（解析时排除该格）
        XCTAssertEqual(sel.startCol, 5)
        XCTAssertEqual(sel.endCol, 10)
    }

    func testDragRightEndOnRightHalfIncludesEndCell() {
        let sel = TextSelection.single(absoluteRow: 0, col: 5)
            .updateEnd(absoluteRow: 0, col: 10, side: .right)
        XCTAssertEqual(sel.startSide, .left)
        XCTAssertEqual(sel.endSide, .right)    // col10 右半 → 含该格
    }

    // MARK: - 向左拖：锚点仍恒含（作为末端 → .right）

    func testDragLeftAnchorRemainsIncluded() {
        // 按下 col10，向左拖到 col5
        let sel = TextSelection.single(absoluteRow: 0, col: 10)
            .updateEnd(absoluteRow: 0, col: 5, side: .right)
        // 锚点 col10 现为末端 → .right 保证仍被包含（旧行为不回归）
        XCTAssertEqual(sel.startSide, .right)
        XCTAssertEqual(sel.startCol, 10)       // 起点仍是锚点
        XCTAssertEqual(sel.endCol, 5)          // 终点是活动端
        XCTAssertEqual(sel.endSide, .right)    // col5 活动端半格
    }

    func testDragLeftEndHalfIsCarried() {
        let sel = TextSelection.single(absoluteRow: 0, col: 10)
            .updateEnd(absoluteRow: 0, col: 5, side: .left)
        XCTAssertEqual(sel.startSide, .right)  // 锚点仍含
        XCTAssertEqual(sel.endSide, .left)     // 活动端 col5 左半
    }

    // MARK: - 跨行向上拖（锚点在后）

    func testDragUpwardAnchorIsTrailingAndIncluded() {
        // 按下 (row5,col3)，向上拖到 (row2,col8)
        let sel = TextSelection.single(absoluteRow: 5, col: 3)
            .updateEnd(absoluteRow: 2, col: 8, side: .left)
        XCTAssertEqual(sel.startSide, .right)  // 锚点 row5 在后 → .right 恒含
        XCTAssertEqual(sel.endSide, .left)     // 活动端 row2,col8 半格
    }

    // MARK: - 拖回锚点同格 → 整格，不变空

    func testDragBackToAnchorKeepsFullCell() {
        let sel = TextSelection.single(absoluteRow: 0, col: 5)
            .updateEnd(absoluteRow: 0, col: 5, side: .left)
        XCTAssertEqual(sel.startSide, .left)
        XCTAssertEqual(sel.endSide, .right)    // 同点 → 强制整格（非空）
    }
}
