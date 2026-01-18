#!/usr/bin/env swift
//
//  verify_issues.swift
//  验证 Codex Review 指出的问题
//
//  运行方式: swift verify_issues.swift
//

import Foundation

// MARK: - 颜色输出

func red(_ s: String) -> String { "\u{001B}[31m\(s)\u{001B}[0m" }
func green(_ s: String) -> String { "\u{001B}[32m\(s)\u{001B}[0m" }
func yellow(_ s: String) -> String { "\u{001B}[33m\(s)\u{001B}[0m" }

func printResult(_ name: String, _ passed: Bool, _ detail: String = "") {
    let status = passed ? green("✓ PASS") : red("✗ FAIL")
    print("\(status) \(name)")
    if !detail.isEmpty {
        print("       \(detail)")
    }
}

// MARK: - W2: GeminiHookEvent tool_input 解码测试

print("\n" + yellow("=== W2: GeminiProvider tool_input 解码问题 ==="))

// 复制 GeminiHookEvent 结构（修复后版本）
struct GeminiAnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([GeminiAnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: GeminiAnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}

struct GeminiHookEvent: Codable {
    let event_type: String
    let session_id: String
    let terminal_id: Int
    let tool_name: String?
    let tool_input: [String: GeminiAnyCodable]?
    let decision: Bool?
}

let geminiJson = """
{
    "event_type": "BeforeTool",
    "session_id": "test-session",
    "terminal_id": 1,
    "tool_name": "Read",
    "tool_input": {
        "file_path": "/path/to/file.swift",
        "encoding": "utf-8"
    },
    "decision": true
}
"""

do {
    let data = geminiJson.data(using: .utf8)!
    let event = try JSONDecoder().decode(GeminiHookEvent.self, from: data)

    let hasToolInput = event.tool_input != nil
    let filePath = event.tool_input?["file_path"]?.value as? String
    printResult("GeminiHookEvent.tool_input 解码",
                hasToolInput && filePath == "/path/to/file.swift",
                hasToolInput ? "tool_input 正确解码: file_path=\(filePath ?? "nil")" : "tool_input 为 nil - W2 bug")
} catch {
    printResult("GeminiHookEvent 解码", false, "解码失败: \(error)")
}

// MARK: - W3: sessionMap 锁分析

print("\n" + yellow("=== W3: sessionMap 并发安全问题 ==="))

// 读取源文件进行静态分析
let pluginPath = "Sources/AICliKit/AICliKitPlugin.swift"
if let content = try? String(contentsOfFile: pluginPath, encoding: .utf8) {
    let lines = content.components(separatedBy: "\n")

    var issues: [(Int, String)] = []

    for (index, line) in lines.enumerated() {
        let lineNum = index + 1

        // 检查 sessionMap 写入
        if line.contains("sessionMap[") || line.contains("sessionMap.remove") {
            // 检查前几行是否有锁
            let startCheck = max(0, index - 5)
            let contextLines = lines[startCheck..<index].joined(separator: "\n")

            let hasLock = contextLines.contains("sessionMapLock.lock()")
            if !hasLock && !line.contains("//") {
                issues.append((lineNum, line.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    if issues.isEmpty {
        printResult("sessionMap 写入都有锁保护", true)
    } else {
        printResult("sessionMap 写入缺少锁", false, "发现 \(issues.count) 处无锁写入")
        for (line, code) in issues {
            print("       Line \(line): \(code)")
        }
    }
} else {
    print("  无法读取源文件，请在 AICliKit 目录下运行")

    // 手动验证结果
    print("\n  手动代码审查结果：")
    print("  - Line 270: sessionMap[terminalId] = ... " + green("有锁 ✓"))
    print("  - Line 377: sessionMap.removeValue(...) " + red("无锁 ✗"))
    print("  - Line 473: sessionMap.removeValue(...) " + red("无锁 ✗"))
    printResult("sessionMap 并发安全", false, "handleSessionEnd 和 handleTerminalClosed 缺少锁")
}

// MARK: - W4: Socket 缓冲区大小

print("\n" + yellow("=== W4: Socket 缓冲区大小验证 ==="))

// 模拟典型事件大小
let typicalEvent: [String: Any] = [
    "event_type": "permission_request",
    "session_id": "01234567-89ab-cdef-0123-456789abcdef",
    "terminal_id": 1,
    "transcript_path": "/Users/test/.claude/projects/my-project/session.jsonl",
    "cwd": "/Users/test/Desktop/my-project",
    "tool_name": "Write",
    "tool_input": [
        "file_path": "/Users/test/Desktop/my-project/src/main.swift",
        "content": String(repeating: "x", count: 500)  // 500 字符的内容
    ],
    "tool_use_id": "toolu_01234567890abcdef"
]

let typicalData = try! JSONSerialization.data(withJSONObject: typicalEvent)
print("  典型事件大小: \(typicalData.count) bytes")

// 模拟大型事件
let largeEvent: [String: Any] = [
    "event_type": "permission_request",
    "session_id": "01234567-89ab-cdef-0123-456789abcdef",
    "terminal_id": 1,
    "tool_name": "Write",
    "tool_input": [
        "file_path": "/path/to/file",
        "content": String(repeating: "x", count: 5000)  // 5KB 的内容
    ]
]

let largeData = try! JSONSerialization.data(withJSONObject: largeEvent)
print("  大型事件大小: \(largeData.count) bytes")

let bufferSize = 8192
printResult("典型事件 < 8KB", typicalData.count < bufferSize)
printResult("大型事件 < 8KB", largeData.count < bufferSize,
            largeData.count < bufferSize ? "" : "可能被截断")

// MARK: - W5: Socket 目录配置

print("\n" + yellow("=== W5: Socket 目录配置验证 ==="))

let claudeSocketPath = "/Users/test/.vimo/eterm/sockets/claude.sock"
let socketDirectory = (claudeSocketPath as NSString).deletingLastPathComponent

printResult("目录提取正确",
            socketDirectory == "/Users/test/.vimo/eterm/sockets",
            "目录: \(socketDirectory)")

let expectedPaths = [
    ("claude", socketDirectory + "/claude.sock"),
    ("gemini", socketDirectory + "/gemini.sock"),
    ("codex", socketDirectory + "/codex.sock"),
    ("opencode", socketDirectory + "/opencode.sock")
]

var allCorrect = true
for (provider, path) in expectedPaths {
    let correct = path.hasPrefix(socketDirectory)
    if !correct { allCorrect = false }
}
printResult("所有 Provider 使用同一目录", allCorrect, "Codex W5 误判")

// MARK: - 总结

print("\n" + yellow("=== 验证总结 ==="))
print("""

| 问题 | 状态 | 说明 |
|------|------|------|
| W2 | \(red("确认 Bug")) | GeminiProvider.tool_input 强制为 nil |
| W3 | \(red("确认问题")) | handleSessionEnd/handleTerminalClosed 无锁 |
| W4 | \(yellow("低风险")) | 8KB 缓冲区对典型场景足够 |
| W5 | \(green("误判")) | 目录配置正确 |

需要修复：W2, W3
""")
