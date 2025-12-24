import Foundation

// 简单的日志函数（替代主程序的全局 log 函数）
func logInfo(_ message: String) {
    print("[McpRouterKit] INFO: \(message)")
}

func logWarn(_ message: String) {
    print("[McpRouterKit] WARN: \(message)")
}

func logError(_ message: String) {
    print("[McpRouterKit] ERROR: \(message)")
}

func logDebug(_ message: String) {
    print("[McpRouterKit] DEBUG: \(message)")
}
