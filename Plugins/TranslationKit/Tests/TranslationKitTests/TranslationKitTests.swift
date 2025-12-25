//
//  TranslationKitTests.swift
//  TranslationKitTests

import XCTest
@testable import TranslationKit

final class TranslationKitTests: XCTestCase {

    func testDefaultConfig() {
        let config = TranslationConfig.default
        XCTAssertEqual(config.dispatcherModel, "qwen-flash")
        XCTAssertEqual(config.analysisModel, "qwen3-max")
        XCTAssertEqual(config.translationModel, "qwen-mt-flash")
    }

    func testPluginId() {
        XCTAssertEqual(TranslationKit.pluginId, "com.eterm.translation")
    }

    func testVersion() {
        XCTAssertEqual(TranslationKit.version, "1.0.0")
    }
}
