//
//  MCPFocusTarget.swift
//  ETerm
//
//  MCP switch_focus 输入模型
//

import Foundation

/// MCP switch_focus 工具的输入参数
struct MCPFocusTarget: Codable, Sendable {
    let type: TargetType
    let windowNumber: Int
    let pageId: String?
    let panelId: String?
    let tabId: String?

    enum TargetType: String, Codable, Sendable {
        case page
        case tab
    }

    /// 验证参数是否完整
    func validate() -> Result<Void, MCPFocusError> {
        switch type {
        case .page:
            guard pageId != nil else {
                return .failure(.missingPageId)
            }
        case .tab:
            guard panelId != nil, tabId != nil else {
                return .failure(.missingTabInfo)
            }
        }
        return .success(())
    }
}

/// switch_focus 操作的错误类型
enum MCPFocusError: Error, LocalizedError {
    case missingPageId
    case missingTabInfo
    case windowNotFound(Int)
    case pageNotFound(String)
    case panelNotFound(String)
    case tabNotFound(String)
    case switchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPageId:
            return "pageId is required when type is 'page'"
        case .missingTabInfo:
            return "panelId and tabId are required when type is 'tab'"
        case .windowNotFound(let number):
            return "Window \(number) not found"
        case .pageNotFound(let id):
            return "Page \(id) not found"
        case .panelNotFound(let id):
            return "Panel \(id) not found"
        case .tabNotFound(let id):
            return "Tab \(id) not found"
        case .switchFailed(let reason):
            return "Switch failed: \(reason)"
        }
    }
}

/// switch_focus 操作的响应
struct MCPFocusResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let focusedElement: FocusedElement?

    struct FocusedElement: Codable, Sendable {
        let windowNumber: Int
        let pageId: String?
        let panelId: String?
        let tabId: String?
    }

    static func success(message: String, element: FocusedElement) -> MCPFocusResponse {
        MCPFocusResponse(success: true, message: message, focusedElement: element)
    }

    static func failure(message: String) -> MCPFocusResponse {
        MCPFocusResponse(success: false, message: message, focusedElement: nil)
    }
}
