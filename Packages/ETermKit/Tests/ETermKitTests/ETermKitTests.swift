import Testing
import Foundation
@testable import ETermKit

@Test func testIPCMessageSerialization() async throws {
    let message = IPCMessage(
        type: .event,
        pluginId: "com.example.test",
        payload: [
            "eventName": "core.terminal.didCreate",
            "terminalId": 1
        ]
    )

    let jsonData = try message.toJSONData()
    let decoded = try IPCMessage.from(jsonData: jsonData)

    #expect(decoded.id == message.id)
    #expect(decoded.type == message.type)
    #expect(decoded.pluginId == message.pluginId)
}

@Test func testPluginManifestDecoding() async throws {
    let json = """
    {
        "id": "com.example.test",
        "name": "Test Plugin",
        "version": "1.0.0",
        "minHostVersion": "2.0.0",
        "sdkVersion": "1.0.0",
        "dependencies": [],
        "capabilities": ["terminal.write"],
        "principalClass": "TestPlugin",
        "sidebarTabs": [],
        "commands": [],
        "subscribes": []
    }
    """

    let data = json.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

    #expect(manifest.id == "com.example.test")
    #expect(manifest.capabilities.contains("terminal.write"))
}

@Test func testAnyCodable() async throws {
    let original: [String: Any] = [
        "string": "hello",
        "int": 42,
        "bool": true,
        "array": [1, 2, 3],
        "nested": ["key": "value"]
    ]

    let wrapped = AnyCodable.wrap(original)
    let unwrapped = AnyCodable.unwrap(wrapped)

    #expect(unwrapped["string"] as? String == "hello")
    #expect(unwrapped["int"] as? Int == 42)
    #expect(unwrapped["bool"] as? Bool == true)
}
