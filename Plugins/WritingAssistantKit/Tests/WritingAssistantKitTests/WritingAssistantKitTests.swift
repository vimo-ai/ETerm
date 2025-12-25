//
//  WritingAssistantKitTests.swift
//  WritingAssistantKitTests
//
//  写作助手插件测试
//

import Testing
@testable import WritingAssistantKit

@Test func testPluginId() async throws {
    #expect(WritingAssistantPlugin.id == "com.eterm.writing-assistant")
}

@Test func testVersion() async throws {
    #expect(WritingAssistantKit.version == "1.0.0")
}
