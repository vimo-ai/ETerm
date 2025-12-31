//
//  SendInputTool.swift
//  ETerm
//
//  MCP send_input tool - send text to terminal
//

import Foundation
import AppKit

/// send_input tool
enum SendInputTool {

    struct Input: Codable {
        let terminalId: Int
        let text: String
        let pressEnter: Bool?
    }

    struct Response: Codable {
        let success: Bool
        let message: String
    }

    /// Execute send_input
    /// - Parameters:
    ///   - terminalId: Terminal ID
    ///   - text: Text to send
    ///   - pressEnter: If true, send Enter key after a 50ms delay (like VlaudePlugin)
    @MainActor
    static func execute(terminalId: Int, text: String, pressEnter: Bool = false) async -> Response {
        // 使用 CoreTerminalService 统一实现
        let result = await CoreTerminalService.sendInput(
            terminalId: terminalId,
            text: text,
            pressEnter: pressEnter
        )

        return Response(success: result.success, message: result.message)
    }

    /// Encode response to JSON
    static func responseToJSON(_ response: Response) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        do {
            let jsonData = try encoder.encode(response)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"success\": false, \"message\": \"\(error.localizedDescription)\"}"
        }
    }
}
