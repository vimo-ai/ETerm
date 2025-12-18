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
    }

    struct Response: Codable {
        let success: Bool
        let message: String
    }

    /// Execute send_input
    @MainActor
    static func execute(terminalId: Int, text: String) -> Response {
        let windowManager = WindowManager.shared

        // Find the coordinator that owns this terminal
        for window in windowManager.windows {
            guard let coordinator = windowManager.getCoordinator(for: window.windowNumber) else {
                continue
            }

            // Check if this coordinator has the terminal
            for page in coordinator.terminalWindow.pages {
                for panel in page.allPanels {
                    for tab in panel.tabs {
                        if tab.rustTerminalId == terminalId {
                            // Found the terminal, send input
                            coordinator.writeInput(terminalId: terminalId, data: text)
                            return Response(success: true, message: "Input sent to terminal \(terminalId)")
                        }
                    }
                }
            }
        }

        return Response(success: false, message: "Terminal \(terminalId) not found")
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
