//
//  DropIntentQueue.swift
//  ETerm
//
//  Drop 意图队列 - 统一管理所有拖拽意图的执行时序
//
//  设计原则：
//  - drop 时只捕获意图，不执行任何模型变更
//  - 等待 drag session 完全结束后才执行
//  - 不依赖硬编码延迟，而是等待 AppKit 回调

import Foundation

/// 布局目标位置
struct LayoutPosition {
    let targetPanelId: UUID
    let direction: SplitDirection
}

/// Drop 意图类型
enum DropIntent {
    /// 同 Panel 内 Tab 重排序
    case reorderTabs(panelId: UUID, tabIds: [UUID])

    /// 跨 Panel 移动 Tab（合并到目标 Panel）
    case moveTabToPanel(tabId: UUID, sourcePanelId: UUID, targetPanelId: UUID)

    /// 分割 Panel（创建新 Panel，源 Panel 有多个 Tab）
    case splitWithNewPanel(tabId: UUID, sourcePanelId: UUID, targetPanelId: UUID, edge: EdgeDirection)

    /// 移动 Panel 到新位置（源 Panel 只有 1 个 Tab，复用 Panel）
    case movePanelInLayout(panelId: UUID, targetPanelId: UUID, edge: EdgeDirection)

    /// 跨窗口移动 Tab
    case moveTabAcrossWindow(tabId: UUID, sourcePanelId: UUID, sourceWindowNumber: Int, targetPanelId: UUID, targetWindowNumber: Int)
}

/// Drop 意图队列
///
/// 统一管理拖拽操作的时序：
/// 1. performDragOperation 时提交意图（Phase 1）
/// 2. 等待 tabDragSessionEnded 通知
/// 3. 在下一个 runloop 执行意图（Phase 2）
final class DropIntentQueue {
    static let shared = DropIntentQueue()

    private init() {}

    // MARK: - State

    /// 待执行的意图
    private var pendingIntent: DropIntent?

    /// drag session 结束通知的观察者
    private var dragSessionObserver: NSObjectProtocol?

    /// 备用超时任务
    private var timeoutWorkItem: DispatchWorkItem?

    // MARK: - Public API

    /// 提交意图（Phase 1: 捕获）
    ///
    /// 在 performDragOperation 中调用，只记录意图，不执行任何模型变更
    ///
    /// - Parameter intent: 拖拽意图
    func submit(_ intent: DropIntent) {
        // 如果已有待处理意图，先取消
        cancelPending()

        pendingIntent = intent
        DragLock.shared.lock()

        // 监听 drag session 结束通知
        dragSessionObserver = NotificationCenter.default.addObserver(
            forName: .tabDragSessionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // 移除监听器
            self.removeObserver()

            // 取消超时
            self.cancelTimeout()

            // 在下一个 runloop 执行（确保当前调用栈完全结束）
            DispatchQueue.main.async { [weak self] in
                self?.executeIntent()
            }
        }

        // 备用超时（200ms）- 防止通知丢失
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.pendingIntent != nil else { return }

            self.removeObserver()
            self.executeIntent()
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// 取消待处理的意图
    func cancelPending() {
        if pendingIntent != nil {
        }
        pendingIntent = nil
        removeObserver()
        cancelTimeout()
        DragLock.shared.unlock()
    }

    // MARK: - Private

    /// 执行意图（Phase 2: 执行）
    private func executeIntent() {
        guard let intent = pendingIntent else {
            DragLock.shared.unlock()
            return
        }
        pendingIntent = nil


        // 发送执行通知，由 Coordinator 处理
        NotificationCenter.default.post(
            name: .executeDropIntent,
            object: nil,
            userInfo: ["intent": intent]
        )

        // 延迟解锁，给 UI 更新时间
        DispatchQueue.main.async {
            DragLock.shared.unlock()
        }
    }

    private func removeObserver() {
        if let observer = dragSessionObserver {
            NotificationCenter.default.removeObserver(observer)
            dragSessionObserver = nil
        }
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// 执行 drop 意图通知
    static let executeDropIntent = Notification.Name("executeDropIntent")

    /// 应用 Tab 重排序通知（视图层）
    static let applyTabReorder = Notification.Name("applyTabReorder")
}
