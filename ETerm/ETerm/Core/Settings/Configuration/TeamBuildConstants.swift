//
//  TeamBuildConstants.swift
//  ETerm
//
//  Compile-time constants for team (commercial) builds.
//  Integrators: edit the values below before building the team edition,
//  or inject them through an .xcconfig file.
//
//  This file is only compiled when TEAM_BUILD is defined.
//

import Foundation

#if TEAM_BUILD
/// Compile-time constants for the team build.
///
/// All values below should be customised per deployment before compiling.
/// They are baked into the binary and cannot be changed at runtime.
enum TeamBuildConstants {
    /// AI service API key (DashScope)
    static let aiApiKey = "REPLACE_WITH_TEAM_API_KEY"

    /// AI service base URL
    static let aiBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    /// Ollama base URL (set to empty string to disable)
    static let ollamaBaseURL = "http://localhost:11434"

    /// Ollama model name
    static let ollamaModel = "qwen3:0.6b"
}
#endif
