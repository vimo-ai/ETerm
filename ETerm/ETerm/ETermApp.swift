//
//  ETermApp.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI

@main
struct ETermApp: App {
    init() {
        // Debug: 全局键盘事件监听
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.control) {
                print("[GlobalMonitor] Ctrl+key: keyCode=\(event.keyCode), chars=\(event.characters ?? "nil")")
            }
            return event
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }
}
