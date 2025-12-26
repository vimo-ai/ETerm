// __PLUGIN_NAME__ViewProvider.swift
// __PLUGIN_NAME__Kit
//
// ViewProvider - provides SwiftUI views to main process

import Foundation
import SwiftUI
import ETermKit

/// __PLUGIN_NAME__ ViewProvider
@objc(__PLUGIN_NAME__ViewProvider)
public final class __PLUGIN_NAME__ViewProvider: NSObject, PluginViewProvider {

    public required override init() {
        super.init()
        print("[__PLUGIN_NAME__ViewProvider] Initialized")
    }

    @MainActor
    public func view(for tabId: String) -> AnyView {
        print("[__PLUGIN_NAME__ViewProvider] Creating sidebar view for tab: \(tabId)")

        // TODO: Add your sidebar tabs here
        return AnyView(
            Text("__PLUGIN_NAME__")
                .foregroundColor(.secondary)
        )
    }
}
