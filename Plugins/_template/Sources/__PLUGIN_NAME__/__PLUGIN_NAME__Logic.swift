// __PLUGIN_NAME__Logic.swift
// __PLUGIN_NAME__
//
// Plugin logic - runs in Extension Host process

import Foundation
import ETermKit

/// Plugin logic entry point
@objc(__PRINCIPAL_CLASS__)
public final class __PRINCIPAL_CLASS__: NSObject, PluginLogic {

    public static var id: String { "__PLUGIN_ID__" }

    private var host: HostBridge?

    public required override init() {
        super.init()
        print("[__PRINCIPAL_CLASS__] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[__PRINCIPAL_CLASS__] Activated")
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
}
