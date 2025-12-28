import PackagePlugin
import Foundation

/// ETerm Plugin Manifest 验证插件
///
/// 在 swift build 时自动验证 Resources/manifest.json
@main
struct ValidateManifestPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // 只处理源码目标
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        // 查找 manifest.json
        // 源码目录: Sources/PluginName
        // manifest: Resources/manifest.json
        let sourceDirURL = URL(filePath: String(describing: sourceTarget.directory))
        let projectRoot = sourceDirURL.deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = projectRoot.appendingPathComponent("Resources").appendingPathComponent("manifest.json")
        let manifestPath = manifestURL.path

        // Debug 输出
        Diagnostics.remark("ValidateManifest: checking \(manifestPath)")

        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            // 没有 manifest.json，跳过验证（可能不是插件项目）
            Diagnostics.remark("ValidateManifest: no manifest.json found, skipping")
            return []
        }

        // 验证 manifest
        do {
            try validateManifest(at: manifestPath)
            Diagnostics.remark("[\(target.name)] manifest.json validated successfully")
        } catch {
            // 使用 Diagnostics.error 输出错误
            Diagnostics.error("[\(target.name)] manifest.json validation failed: \(error)")
            throw error
        }

        return []
    }

    private func validateManifest(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        // 解析 JSON
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError.invalidJSON
        }

        // 验证必填字段
        let requiredFields = ["id", "name", "version", "minHostVersion", "sdkVersion", "principalClass"]
        for field in requiredFields {
            guard json[field] != nil else {
                throw ManifestError.missingField(field)
            }
        }

        // 验证 id 格式
        if let id = json["id"] as? String {
            let pattern = "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)+$"
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(id.startIndex..., in: id)
            if regex?.firstMatch(in: id, range: range) == nil {
                throw ManifestError.invalidFormat(field: "id", value: id, expected: "reverse domain (e.g., com.example.plugin)")
            }
        }

        // 验证 runMode
        if let runMode = json["runMode"] as? String {
            let validModes = ["main", "isolated"]
            if !validModes.contains(runMode) {
                throw ManifestError.invalidEnum(field: "runMode", value: runMode, valid: validModes)
            }
        }

        // 验证 loadPriority
        if let loadPriority = json["loadPriority"] as? String {
            let validPriorities = ["immediate", "background", "lazy"]
            if !validPriorities.contains(loadPriority) {
                throw ManifestError.invalidEnum(field: "loadPriority", value: loadPriority, valid: validPriorities)
            }
        }

        // 验证 sidebarTabs
        if let sidebarTabs = json["sidebarTabs"] as? [[String: Any]] {
            for (index, tab) in sidebarTabs.enumerated() {
                let tabRequired = ["id", "title", "icon", "viewClass"]
                for field in tabRequired {
                    guard tab[field] != nil else {
                        throw ManifestError.missingField("sidebarTabs[\(index)].\(field)")
                    }
                }
                // 验证 renderMode
                if let renderMode = tab["renderMode"] as? String {
                    let validModes = ["inline", "tab"]
                    if !validModes.contains(renderMode) {
                        throw ManifestError.invalidEnum(
                            field: "sidebarTabs[\(index)].renderMode",
                            value: renderMode,
                            valid: validModes
                        )
                    }
                }
            }
        }

        // 验证 tabSlots
        if let tabSlots = json["tabSlots"] as? [[String: Any]] {
            for (index, slot) in tabSlots.enumerated() {
                guard slot["id"] != nil else {
                    throw ManifestError.missingField("tabSlots[\(index)].id")
                }
                guard slot["position"] != nil else {
                    throw ManifestError.missingField("tabSlots[\(index)].position")
                }
                if let position = slot["position"] as? String {
                    let validPositions = ["leading", "trailing"]
                    if !validPositions.contains(position) {
                        throw ManifestError.invalidEnum(
                            field: "tabSlots[\(index)].position",
                            value: position,
                            valid: validPositions
                        )
                    }
                }
            }
        }

        // 验证 pageSlots
        if let pageSlots = json["pageSlots"] as? [[String: Any]] {
            for (index, slot) in pageSlots.enumerated() {
                guard slot["id"] != nil else {
                    throw ManifestError.missingField("pageSlots[\(index)].id")
                }
                guard slot["position"] != nil else {
                    throw ManifestError.missingField("pageSlots[\(index)].position")
                }
                if let position = slot["position"] as? String {
                    let validPositions = ["leading", "trailing"]
                    if !validPositions.contains(position) {
                        throw ManifestError.invalidEnum(
                            field: "pageSlots[\(index)].position",
                            value: position,
                            valid: validPositions
                        )
                    }
                }
            }
        }

        // 验证 dependencies
        if let dependencies = json["dependencies"] as? [[String: Any]] {
            for (index, dep) in dependencies.enumerated() {
                guard dep["id"] != nil else {
                    throw ManifestError.missingField("dependencies[\(index)].id")
                }
                guard dep["minVersion"] != nil else {
                    throw ManifestError.missingField("dependencies[\(index)].minVersion")
                }
            }
        }

        // 验证 commands
        if let commands = json["commands"] as? [[String: Any]] {
            for (index, cmd) in commands.enumerated() {
                let cmdRequired = ["id", "title", "handler"]
                for field in cmdRequired {
                    guard cmd[field] != nil else {
                        throw ManifestError.missingField("commands[\(index)].\(field)")
                    }
                }
            }
        }

        // 验证 bottomDock
        if let bottomDock = json["bottomDock"] as? [String: Any] {
            guard bottomDock["id"] != nil else {
                throw ManifestError.missingField("bottomDock.id")
            }
            guard bottomDock["viewClass"] != nil else {
                throw ManifestError.missingField("bottomDock.viewClass")
            }
        }

        // 验证 menuBar
        if let menuBar = json["menuBar"] as? [String: Any] {
            guard menuBar["id"] != nil else {
                throw ManifestError.missingField("menuBar.id")
            }
        }

        // 验证 bubble
        if let bubble = json["bubble"] as? [String: Any] {
            let bubbleRequired = ["id", "hintIcon", "contentViewClass"]
            for field in bubbleRequired {
                guard bubble[field] != nil else {
                    throw ManifestError.missingField("bubble.\(field)")
                }
            }
        }

        // 验证 infoPanelContents
        if let contents = json["infoPanelContents"] as? [[String: Any]] {
            for (index, content) in contents.enumerated() {
                let contentRequired = ["id", "title", "viewClass"]
                for field in contentRequired {
                    guard content[field] != nil else {
                        throw ManifestError.missingField("infoPanelContents[\(index)].\(field)")
                    }
                }
            }
        }

        // 验证 pageBarItems
        if let items = json["pageBarItems"] as? [[String: Any]] {
            for (index, item) in items.enumerated() {
                let itemRequired = ["id", "viewClass"]
                for field in itemRequired {
                    guard item[field] != nil else {
                        throw ManifestError.missingField("pageBarItems[\(index)].\(field)")
                    }
                }
            }
        }
    }
}

enum ManifestError: Error, CustomStringConvertible {
    case invalidJSON
    case missingField(String)
    case invalidFormat(field: String, value: String, expected: String)
    case invalidEnum(field: String, value: String, valid: [String])
    case validationFailed(target: String, error: Error)

    var description: String {
        switch self {
        case .invalidJSON:
            return "manifest.json is not valid JSON"
        case .missingField(let field):
            return "Missing required field: '\(field)'"
        case .invalidFormat(let field, let value, let expected):
            return "Invalid format for '\(field)': '\(value)' (expected: \(expected))"
        case .invalidEnum(let field, let value, let valid):
            return "Invalid value for '\(field)': '\(value)' (valid: \(valid.joined(separator: ", ")))"
        case .validationFailed(let target, let error):
            return "[\(target)] manifest.json validation failed: \(error)"
        }
    }
}
