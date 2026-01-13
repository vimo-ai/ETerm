//
//  MCPConfigManager.swift
//  MCPRouterKit
//
//  处理项目级 .mcp.json 文件的读写和合并
//

import Foundation

public struct MCPConfigManager {

    // MARK: - 状态查询

    /// 检查项目目录下是否存在 .mcp.json
    public static func configFileExists(at projectPath: String) -> Bool {
        let configPath = (projectPath as NSString).appendingPathComponent(".mcp.json")
        return FileManager.default.fileExists(atPath: configPath)
    }

    /// 读取 .mcp.json 配置
    public static func readConfig(at projectPath: String) throws -> [String: Any] {
        let configPath = (projectPath as NSString).appendingPathComponent(".mcp.json")

        guard FileManager.default.fileExists(atPath: configPath) else {
            return [:]
        }

        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConfigError.invalidFormat
        }

        return json
    }

    /// 检查是否已有 mcp-router 配置
    public static func hasRouterConfig(at projectPath: String) -> (exists: Bool, token: String?) {
        do {
            let config = try readConfig(at: projectPath)

            guard let servers = config["mcpServers"] as? [String: Any],
                  let routerConfig = servers["mcp-router"] as? [String: Any] else {
                return (false, nil)
            }

            // 提取 Token
            if let headers = routerConfig["headers"] as? [String: String],
               let token = headers["X-Workspace-Token"] {
                return (true, token)
            }

            return (true, nil)
        } catch {
            return (false, nil)
        }
    }

    // MARK: - 安装 & 卸载

    /// 合并并写入 mcp-router 配置到项目 .mcp.json
    public static func installToProject(
        at projectPath: String,
        token: String,
        port: Int
    ) throws {
        let routerURL = "http://localhost:\(port)"
        let configPath = (projectPath as NSString).appendingPathComponent(".mcp.json")
        let configURL = URL(fileURLWithPath: configPath)

        // 读取现有配置
        var config = try readConfig(at: projectPath)

        // 合并 mcpServers
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["mcp-router"] = [
            "type": "http",
            "url": routerURL,
            "headers": [
                "X-Workspace-Token": token
            ]
        ]
        config["mcpServers"] = servers

        // 写回文件（格式化）
        let jsonData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try jsonData.write(to: configURL)
    }

    /// 从项目 .mcp.json 中移除 mcp-router 配置
    public static func uninstallFromProject(at projectPath: String) throws {
        let configPath = (projectPath as NSString).appendingPathComponent(".mcp.json")
        let configURL = URL(fileURLWithPath: configPath)

        var config = try readConfig(at: projectPath)

        guard var servers = config["mcpServers"] as? [String: Any] else {
            return
        }

        servers.removeValue(forKey: "mcp-router")

        if servers.isEmpty {
            // 如果没有其他 server，删除整个文件
            try? FileManager.default.removeItem(at: configURL)
        } else {
            config["mcpServers"] = servers
            let jsonData = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: configURL)
        }
    }

    /// 生成配置预览文本
    public static func generateConfigPreview(token: String, port: Int) -> String {
        let routerURL = "http://localhost:\(port)"
        let config: [String: Any] = [
            "mcpServers": [
                "mcp-router": [
                    "type": "http",
                    "url": routerURL,
                    "headers": [
                        "X-Workspace-Token": token
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }

        return jsonString
    }
}

// MARK: - Errors

public enum MCPConfigError: LocalizedError {
    case invalidFormat
    case fileNotFound
    case writeError

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "配置文件格式无效"
        case .fileNotFound:
            return "配置文件不存在"
        case .writeError:
            return "写入配置文件失败"
        }
    }
}
