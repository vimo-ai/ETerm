//
//  SelectionPopoverController.swift
//  ETerm
//
//  选中 Popover 控制器

import SwiftUI
import AppKit
import ETermKit

/// 选中 Popover 控制器
///
/// 在终端选中文本时显示 Action 菜单。
@MainActor
final class SelectionPopoverController: NSObject {

    static let shared = SelectionPopoverController()

    // MARK: - Properties

    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .semitransient
        p.animates = true
        return p
    }()

    private weak var sourceView: NSView?
    private var sourceRect: NSRect = .zero
    private var currentText: String = ""

    // MARK: - Lifecycle

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// 显示 Action 菜单
    ///
    /// - Parameters:
    ///   - text: 选中的文本
    ///   - rect: 选中区域的屏幕坐标
    ///   - view: 源视图
    ///   - actions: 要显示的 Actions（已过滤自动触发的）
    func show(text: String, at rect: NSRect, in view: NSView, actions: [SelectionAction]) {
        self.currentText = text
        self.sourceView = view
        self.sourceRect = rect

        guard !actions.isEmpty else {
            logDebug("[SelectionPopoverController] No actions to show")
            return
        }

        // 创建视图
        let contentView = SelectionActionMenuView(
            actions: actions,
            onActionSelected: { [weak self] actionId in
                self?.handleActionSelected(actionId)
            }
        )

        // 设置内容
        let hostingController = NSHostingController(rootView: contentView)
        popover.contentViewController = hostingController

        // 计算尺寸
        let itemHeight: CGFloat = 36
        let padding: CGFloat = 8
        let height = CGFloat(actions.count) * itemHeight + padding * 2
        popover.contentSize = NSSize(width: 160, height: min(height, 300))

        // 显示
        if !popover.isShown {
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    /// 隐藏 Popover
    func hide() {
        popover.performClose(nil)
    }

    /// Popover 是否正在显示
    var isShown: Bool {
        popover.isShown
    }

    // MARK: - Private

    private func handleActionSelected(_ actionId: String) {
        hide()
        triggerAction(actionId, text: currentText)
    }
}

// MARK: - Action 触发

extension SelectionPopoverController {

    /// 触发指定 Action
    ///
    /// 发送通知，由订阅的插件处理。
    ///
    /// - Parameters:
    ///   - actionId: Action ID
    ///   - text: 选中的文本
    ///   - rect: 选中文本的屏幕坐标（可选，用于定位弹窗）
    func triggerAction(_ actionId: String, text: String, at rect: NSRect? = nil) {
        // 优先使用传入的 rect，否则使用保存的 sourceRect
        let effectiveRect = rect ?? sourceRect

        var payload: [String: Any] = [
            "actionId": actionId,
            "text": text
        ]

        if effectiveRect != .zero {
            payload["screenRect"] = effectiveRect
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.SelectionActionTriggered"),
            object: nil,
            userInfo: payload
        )

        logDebug("[SelectionPopoverController] Triggered action: \(actionId), rect: \(effectiveRect)")
    }
}

// MARK: - Action Menu View

private struct SelectionActionMenuView: View {
    let actions: [SelectionAction]
    let onActionSelected: (String) -> Void

    @State private var hoveredId: String?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(actions, id: \.id) { action in
                Button(action: { onActionSelected(action.id) }) {
                    HStack(spacing: 8) {
                        Image(systemName: action.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                            .foregroundStyle(.secondary)

                        Text(action.title)
                            .font(.system(size: 13))

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoveredId == action.id ? Color.primary.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    hoveredId = isHovered ? action.id : nil
                }
            }
        }
        .padding(4)
    }
}
