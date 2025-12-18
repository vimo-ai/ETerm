//
//  MCPSessionInfo.swift
//  ETerm
//
//  MCP list_sessions 响应模型
//

import Foundation

/// MCP list_sessions 工具的响应结构
struct MCPSessionInfo: Codable, Sendable {
    let windows: [WindowInfo]

    struct WindowInfo: Codable, Sendable {
        let windowNumber: Int
        let windowId: String
        let isKeyWindow: Bool
        let pages: [PageInfo]
        let activePageId: String?
    }

    struct PageInfo: Codable, Sendable {
        let pageId: String
        let title: String
        let isActive: Bool
        let panels: [PanelInfo]
    }

    struct PanelInfo: Codable, Sendable {
        let panelId: String
        let isActive: Bool
        let bounds: BoundsInfo  // Panel 在窗口中的位置
        let tabs: [TabInfo]
        let activeTabId: String?
    }

    /// Panel 位置信息（坐标系：左下角为原点，Y 轴向上）
    struct BoundsInfo: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct TabInfo: Codable, Sendable {
        let tabId: String
        let title: String
        let isActive: Bool
        let type: TabType
        let terminalId: Int?
    }

    enum TabType: String, Codable, Sendable {
        case terminal
        case view
    }
}
