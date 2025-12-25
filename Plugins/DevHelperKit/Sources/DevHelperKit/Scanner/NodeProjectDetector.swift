// NodeProjectDetector.swift
// DevHelperKit
//
// Node.js 项目检测器

import Foundation

/// Node.js 项目检测器
public final class NodeProjectDetector: ProjectDetector {
    public let configFileName = "package.json"
    public let projectType = "node"
    public let skipDirectories: Set<String> = ["node_modules", ".next", "dist", "build", ".nuxt", ".output"]

    public init() {}

    public func parse(configPath: URL, folderPath: URL) -> DetectedProject? {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 项目名称：优先用 package.json 的 name，否则用文件夹名
        let name = json["name"] as? String ?? folderPath.lastPathComponent

        // 解析 scripts
        let scripts = parseScripts(from: json, folderPath: folderPath)

        // 如果没有 scripts，也返回项目（可能只是个库）
        return DetectedProject(
            name: name,
            path: folderPath.path,
            type: projectType,
            scripts: scripts
        )
    }

    // MARK: - 私有方法

    private func parseScripts(from json: [String: Any], folderPath: URL) -> [ProjectScript] {
        guard let scripts = json["scripts"] as? [String: String] else {
            return []
        }

        // 检测包管理器
        let packageManager = detectPackageManager(at: folderPath)

        return scripts
            .sorted { $0.key < $1.key }
            .map { name, _ in
                ProjectScript(
                    name: name,
                    command: "\(packageManager) \(name)",
                    displayName: nil
                )
            }
    }

    /// 检测包管理器（pnpm > yarn > npm）
    private func detectPackageManager(at folderPath: URL) -> String {
        let fm = FileManager.default

        // pnpm-lock.yaml
        if fm.fileExists(atPath: folderPath.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }

        // yarn.lock
        if fm.fileExists(atPath: folderPath.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }

        // bun.lockb
        if fm.fileExists(atPath: folderPath.appendingPathComponent("bun.lockb").path) {
            return "bun"
        }

        // 默认 npm
        return "npm run"
    }
}
