import Foundation

struct CLIResumeConfig: Codable {
    var resumeCommand: String
}

struct AICliConfig: Codable {
    var claude: CLIResumeConfig?
    var gemini: CLIResumeConfig?
    var codex: CLIResumeConfig?
    var opencode: CLIResumeConfig?

    func resumeCommand(for providerId: String, sessionId: String) -> String? {
        let template: String?
        switch providerId {
        case "claude":
            template = claude?.resumeCommand ?? "claude --resume {sessionId}"
        case "gemini":
            template = gemini?.resumeCommand
        case "codex":
            template = codex?.resumeCommand
        case "opencode":
            template = opencode?.resumeCommand
        default:
            template = nil
        }
        guard let t = template else { return nil }
        return t.replacingOccurrences(of: "{sessionId}", with: sessionId) + "\n"
    }

    static let `default` = AICliConfig()
}

final class AICliConfigManager {
    static let shared = AICliConfigManager()

    private(set) var config: AICliConfig

    private static var configPath: String {
        let home = NSHomeDirectory()
        return "\(home)/.vimo/eterm/config/cli.json"
    }

    private init() {
        self.config = Self.load() ?? .default
    }

    func reload() {
        self.config = Self.load() ?? .default
    }

    private static func load() -> AICliConfig? {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(AICliConfig.self, from: data) else {
            return nil
        }
        return config
    }
}
