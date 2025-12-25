//
//  TranslationKit.swift
//  TranslationKit
//
//  Translation Plugin SDK Entry Point

import Foundation
import ETermKit

// MARK: - Public Exports

/// TranslationKit - ETerm Translation Plugin
///
/// Provides translation functionality for the ETerm terminal:
/// - Text selection translation
/// - Multi-model AI translation pipeline
/// - Configuration management for dispatcher/analysis/translation models
///
/// ## Plugin Architecture
///
/// This plugin follows the ETermKit SDK architecture:
/// - `TranslationPluginLogic`: Business logic running in Extension Host process
/// - Configuration persisted to `~/.eterm/plugins/Translation/config.json`
/// - UI handled by main application through events
///
/// ## Services Provided
///
/// - `getConfig`: Returns current translation configuration
/// - `updateConfig`: Updates translation model configuration
public struct TranslationKit {
    /// Library version
    public static let version = "1.0.0"

    /// Plugin ID
    public static let pluginId = TranslationPluginLogic.id
}
