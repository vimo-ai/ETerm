//
//  WorkingDirectoryRegistryTests.swift
//  ETermTests
//
//  测试工作目录注册表的状态管理
//

import XCTest
@testable import ETerm

final class WorkingDirectoryRegistryTests: XCTestCase {

    var registry: TerminalWorkingDirectoryRegistry!

    override func setUpWithError() throws {
        registry = TerminalWorkingDirectoryRegistry()
    }

    override func tearDownWithError() throws {
        registry = nil
    }

    // MARK: - WorkingDirectory 值对象测试

    func testWorkingDirectoryUserHome() {
        let cwd = WorkingDirectory.userHome()
        XCTAssertEqual(cwd.path, NSHomeDirectory())
        XCTAssertEqual(cwd.source, .userHome)
        XCTAssertEqual(cwd.priority, 0)
        XCTAssertTrue(cwd.isDefault)
        XCTAssertFalse(cwd.isReliable)
    }

    func testWorkingDirectoryRestored() {
        let cwd = WorkingDirectory.restored(path: "/foo/bar")
        XCTAssertEqual(cwd.path, "/foo/bar")
        XCTAssertEqual(cwd.source, .restored)
        XCTAssertEqual(cwd.priority, 60)
        XCTAssertFalse(cwd.isDefault)
        XCTAssertFalse(cwd.isReliable)
    }

    func testWorkingDirectoryFromOSC7() {
        let cwd = WorkingDirectory.fromOSC7(path: "/projects/myapp")
        XCTAssertEqual(cwd.path, "/projects/myapp")
        XCTAssertEqual(cwd.source, .osc7Cache)
        XCTAssertEqual(cwd.priority, 100)
        XCTAssertTrue(cwd.isReliable)
    }

    func testWorkingDirectoryPriority() {
        let osc7 = WorkingDirectory.fromOSC7(path: "/osc7")
        let proc = WorkingDirectory.fromProcPidinfo(path: "/proc")
        let restored = WorkingDirectory.restored(path: "/restored")
        let inherited = WorkingDirectory.inherited(path: "/inherited")
        let home = WorkingDirectory.userHome()

        XCTAssertGreaterThan(osc7.priority, proc.priority)
        XCTAssertGreaterThan(proc.priority, restored.priority)
        XCTAssertGreaterThan(restored.priority, inherited.priority)
        XCTAssertGreaterThan(inherited.priority, home.priority)
    }

    func testWorkingDirectoryPreferring() {
        let low = WorkingDirectory.userHome()
        let high = WorkingDirectory.fromOSC7(path: "/osc7")

        // 高优先级应该被选中
        XCTAssertEqual(low.preferring(high).path, "/osc7")
        XCTAssertEqual(high.preferring(low).path, "/osc7")
    }

    // MARK: - Registry Pending 状态测试

    func testRegisterPendingTerminal() {
        let tabId = UUID()

        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/foo")
        )

        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(cwd.path, "/foo")
        XCTAssertEqual(cwd.source, .restored)
    }

    func testQueryNonExistentTabReturnsUserHome() {
        let tabId = UUID()

        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(cwd.path, NSHomeDirectory())
        XCTAssertEqual(cwd.source, .userHome)
    }

    // MARK: - Registry Promotion 测试

    func testPromotePendingTerminal() {
        let tabId = UUID()
        let terminalId = 123

        // 注册 pending
        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/foo")
        )

        // 提升到 active
        registry.promotePendingTerminal(tabId: tabId, terminalId: terminalId)

        // 验证状态
        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: terminalId)
        XCTAssertEqual(cwd.path, "/foo")
        XCTAssertEqual(cwd.source, .restored)
    }

    func testRetainPendingTerminalForRetry() {
        let tabId = UUID()

        // 注册 pending
        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/foo")
        )

        // 模拟创建失败，保留状态
        let retained = registry.retainPendingTerminal(tabId: tabId)
        XCTAssertEqual(retained?.path, "/foo")

        // 验证状态仍然存在（可以重试）
        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(cwd.path, "/foo")
    }

    // MARK: - Registry Detach/Reattach 测试

    func testDetachAndReattachTerminal() {
        let tabId = UUID()
        let oldTerminalId = 123
        let newTerminalId = 456

        // 注册 active 终端
        registry.registerActiveTerminal(
            tabId: tabId,
            terminalId: oldTerminalId,
            workingDirectory: .inherited(path: "/foo")
        )

        // 分离
        registry.detachTerminal(tabId: tabId, terminalId: oldTerminalId)

        // 验证分离后可以查询到（通过 tabId）
        let detachedCwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(detachedCwd.path, "/foo")

        // 重新附加
        registry.reattachTerminal(tabId: tabId, newTerminalId: newTerminalId)

        // 验证重新附加后状态正确
        let reattachedCwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: newTerminalId)
        XCTAssertEqual(reattachedCwd.path, "/foo")
    }

    // MARK: - Pool Transition 测试

    func testCaptureAndRestorePoolTransition() {
        let tabId1 = UUID()
        let tabId2 = UUID()

        // 注册两个 active 终端
        registry.registerActiveTerminal(
            tabId: tabId1,
            terminalId: 1,
            workingDirectory: .inherited(path: "/foo")
        )
        registry.registerActiveTerminal(
            tabId: tabId2,
            terminalId: 2,
            workingDirectory: .inherited(path: "/bar")
        )

        // Pool 切换前捕获
        registry.captureBeforePoolTransition(tabIdMapping: [1: tabId1, 2: tabId2])

        // 验证捕获后可以通过 tabId 查询
        let cwd1 = registry.queryWorkingDirectory(tabId: tabId1, terminalId: nil)
        let cwd2 = registry.queryWorkingDirectory(tabId: tabId2, terminalId: nil)
        XCTAssertEqual(cwd1.path, "/foo")
        XCTAssertEqual(cwd2.path, "/bar")

        // Pool 切换后恢复
        registry.restoreAfterPoolTransition(tabIdMapping: [tabId1: 101, tabId2: 102])

        // 验证恢复后状态正确
        let restored1 = registry.queryWorkingDirectory(tabId: tabId1, terminalId: 101)
        let restored2 = registry.queryWorkingDirectory(tabId: tabId2, terminalId: 102)
        XCTAssertEqual(restored1.path, "/foo")
        XCTAssertEqual(restored2.path, "/bar")
    }

    // MARK: - Clear 测试

    func testClearTab() {
        let tabId = UUID()

        // 注册 pending
        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/foo")
        )

        // 清除
        registry.clearTab(tabId: tabId)

        // 验证清除后返回默认值
        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(cwd.source, .userHome)
    }

    func testRemoveTerminal() {
        let tabId = UUID()
        let terminalId = 123

        // 注册 active 终端
        registry.registerActiveTerminal(
            tabId: tabId,
            terminalId: terminalId,
            workingDirectory: .inherited(path: "/foo")
        )

        // 移除
        registry.removeTerminal(terminalId: terminalId)

        // 验证移除后返回默认值
        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: terminalId)
        XCTAssertEqual(cwd.source, .userHome)
    }

    // MARK: - 边界情况测试

    func testMultipleRegisterOverwritesPending() {
        let tabId = UUID()

        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/first")
        )

        registry.registerPendingTerminal(
            tabId: tabId,
            workingDirectory: .restored(path: "/second")
        )

        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: nil)
        XCTAssertEqual(cwd.path, "/second")
    }

    func testNonExistentPromotionIsIgnored() {
        let tabId = UUID()

        // 没有注册就直接 promote，应该被忽略
        registry.promotePendingTerminal(tabId: tabId, terminalId: 123)

        // 查询应该返回默认值
        let cwd = registry.queryWorkingDirectory(tabId: tabId, terminalId: 123)
        XCTAssertEqual(cwd.source, .userHome)
    }
}
