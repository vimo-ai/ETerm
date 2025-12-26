// __PLUGIN_NAME__Logic.swift
// __PLUGIN_NAME__Kit
//
// Plugin logic - runs in Extension Host process

import Foundation
import ETermKit

/// Plugin logic entry point
@objc(__PRINCIPAL_CLASS__)
public final class __PRINCIPAL_CLASS__: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "__PLUGIN_ID__" }

    /// Serial queue to protect mutable state
    private let stateQueue = DispatchQueue(label: "__PLUGIN_ID__.state")
    private var _host: HostBridge?

    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    public required override init() {
        super.init()
        print("[__PRINCIPAL_CLASS__] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[__PRINCIPAL_CLASS__] Activated")

        // Send initial state to View
        updateUI()
    }

    public func deactivate() {
        print("[__PRINCIPAL_CLASS__] Deactivated")
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[__PRINCIPAL_CLASS__] Event: \(eventName)")
    }

    public func handleCommand(_ commandId: String) {
        print("[__PRINCIPAL_CLASS__] Command: \(commandId)")
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[__PRINCIPAL_CLASS__] Request: \(requestId)")

        switch requestId {
        case "getData":
            return ["success": true, "message": "Hello from __PLUGIN_NAME__"]
        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - UI Update

    private func updateUI() {
        host?.updateViewModel(Self.id, data: [
            "message": "Hello from __PLUGIN_NAME__"
        ])
    }
}
