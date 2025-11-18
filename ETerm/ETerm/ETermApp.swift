//
//  ETermApp.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI

@main
struct ETermApp: App {
    @State private var windowController: WindowController?

    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                if let controller = windowController {
                    // 使用新的 DDD 架构
                    ContentView(windowController: controller)
                        .onAppear {
                            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                            controller.resizeContainer(
                                newSize: geometry.size,
                                scale: scale
                            )
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                            controller.resizeContainer(
                                newSize: newSize,
                                scale: scale
                            )
                        }
                } else {
                    Color.clear
                        .onAppear {
                            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                            windowController = WindowController(
                                containerSize: geometry.size,
                                scale: scale
                            )
                        }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }
}
