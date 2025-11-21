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
}
