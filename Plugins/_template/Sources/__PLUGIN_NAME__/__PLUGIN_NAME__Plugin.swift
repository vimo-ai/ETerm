//
//  __PLUGIN_NAME__Plugin.swift
//  __PLUGIN_NAME__Kit
//
//  __PLUGIN_DISPLAY_NAME__ Plugin (main mode)

import Foundation
import SwiftUI
import ETermKit

@objc(__PRINCIPAL_CLASS__)
@MainActor
public final class __PRINCIPAL_CLASS__: NSObject, ETermKit.Plugin {

    public static var id = "__PLUGIN_ID__"

    private var host: HostBridge?

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func activate(host: HostBridge) {
        self.host = host
        print("[__PRINCIPAL_CLASS__] Activated")
    }

    public func deactivate() {
        print("[__PRINCIPAL_CLASS__] Deactivated")
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // Handle subscribed events
        switch eventName {
        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        // Handle registered commands
        switch commandId {
        default:
            break
        }
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        // Return sidebar view for tabId
        // switch tabId {
        // case "my-tab":
        //     return AnyView(MyTabView())
        // default:
        //     return nil
        // }
        return nil
    }

    public func bottomDockView(for id: String) -> AnyView? {
        return nil
    }

    public func infoPanelView(for id: String) -> AnyView? {
        return nil
    }

    public func bubbleView(for id: String) -> AnyView? {
        return nil
    }

    public func menuBarView() -> AnyView? {
        return nil
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        return nil
    }

    public func windowBottomOverlayView(for id: String) -> AnyView? {
        return nil
    }

    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
        return nil
    }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        return nil
    }
}
