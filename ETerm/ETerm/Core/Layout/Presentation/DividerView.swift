//
//  DividerView.swift
//  ETerm
//
//  Panel 分割线视图
//

import AppKit

/// Panel 分割线视图
///
/// 显示在两个 Panel 之间，可用于拖拽调整尺寸
final class DividerView: NSView {
    var direction: SplitDirection = .horizontal

    /// 分割线的视觉宽度
    private let visualThickness: CGFloat = 1.0

    /// 布局路径（从根节点到此分割节点的路径，0=first, 1=second）
    var layoutPath: [Int] = []

    /// Coordinator 引用（用于更新布局）
    weak var coordinator: TerminalWindowCoordinator?

    /// 拖拽时的初始位置
    private var dragStartLocation: CGPoint?

    /// 拖拽时的初始 ratio
    private var initialRatio: CGFloat?

    /// 分割线所在区域的 bounds（用于计算 ratio）
    var splitBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 绘制居中的细线
        NSColor.separatorColor.setFill()

        let lineRect: NSRect
        switch direction {
        case .horizontal:
            // 垂直分割线（左右分割）
            let x = (bounds.width - visualThickness) / 2
            lineRect = NSRect(x: x, y: 0, width: visualThickness, height: bounds.height)
        case .vertical:
            // 水平分割线（上下分割）
            let y = (bounds.height - visualThickness) / 2
            lineRect = NSRect(x: 0, y: y, width: bounds.width, height: visualThickness)
        }

        lineRect.fill()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // 记录初始位置
        dragStartLocation = convert(event.locationInWindow, from: nil)

        // 获取当前 ratio
        initialRatio = getCurrentRatio()

        // 开始事件追踪循环，确保即使鼠标移出视图也能继续接收事件
        trackDragging(with: event)
    }

    /// 追踪拖动事件（确保即使鼠标移出视图也能继续接收事件）
    private func trackDragging(with initialEvent: NSEvent) {
        guard let window = window else { return }

        // 使用事件追踪循环
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { event, stop in
            guard let event = event else {
                stop.pointee = true
                return
            }

            switch event.type {
            case .leftMouseDragged:
                self.handleDrag(with: event)
            case .leftMouseUp:
                self.handleMouseUp(with: event)
                stop.pointee = true
            default:
                break
            }
        }
    }

    /// 处理拖动
    private func handleDrag(with event: NSEvent) {
        guard let startLocation = dragStartLocation,
              let initialRatio = initialRatio,
              let coordinator = coordinator else {
            return
        }

        // 计算拖拽距离
        let currentLocation = convert(event.locationInWindow, from: nil)
        let delta: CGFloat

        switch direction {
        case .horizontal:
            delta = currentLocation.x - startLocation.x
        case .vertical:
            // 向上拖（AppKit delta > 0）→ 下面变大 → ratio 减小 → 需要取反
            delta = -(currentLocation.y - startLocation.y)
        }

        // 计算新的 ratio
        let totalSize: CGFloat = direction == .horizontal ? splitBounds.width : splitBounds.height
        guard totalSize > 0 else { return }

        let deltaRatio = delta / totalSize
        var newRatio = initialRatio + deltaRatio

        // 限制在 0.1 到 0.9 之间（防止 Panel 太小）
        newRatio = max(0.1, min(0.9, newRatio))

        // 更新布局
        coordinator.updateDividerRatio(layoutPath: layoutPath, newRatio: newRatio)
    }

    /// 处理鼠标释放
    private func handleMouseUp(with event: NSEvent) {
        // 重置拖拽状态
        dragStartLocation = nil
        initialRatio = nil

        // 重置光标
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Helper Methods

    /// 从 coordinator 获取当前 ratio
    private func getCurrentRatio() -> CGFloat? {
        guard let coordinator = coordinator else { return nil }

        // 从布局树中获取当前 ratio
        return coordinator.getRatioAtPath(layoutPath)
    }
}
