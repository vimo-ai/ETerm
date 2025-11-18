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
                            // 延迟获取 scale,确保窗口已显示
                            DispatchQueue.main.async {
                                let scale = getWindowScale()
                                controller.resizeContainer(
                                    newSize: geometry.size,
                                    scale: scale
                                )
                            }
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            // 窗口尺寸变化时重新获取 scale (可能跨屏拖动了)
                            let scale = getWindowScale()
                            controller.resizeContainer(
                                newSize: newSize,
                                scale: scale
                            )
                        }
                } else {
                    Color.clear
                        .onAppear {
                            // 延迟初始化,确保窗口已创建
                            DispatchQueue.main.async {
                                let scale = getWindowScale()
                                windowController = WindowController(
                                    containerSize: geometry.size,
                                    scale: scale
                                )
                            }
                        }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }

    // MARK: - Helper Methods

    /// 获取当前窗口所在屏幕的 scale factor
    ///
    /// 优先从应用的主窗口获取,确保获取的是当前窗口实际所在屏幕的 scale
    /// 这样可以正确处理窗口在不同 DPI 屏幕间拖动的情况
    private func getWindowScale() -> CGFloat {
        // 优先从应用的窗口获取 (最准确)
        if let window = NSApp.windows.first,
           let screen = window.screen {
            return screen.backingScaleFactor
        }

        // 降级到主屏幕
        if let mainScreen = NSScreen.main {
            return mainScreen.backingScaleFactor
        }

        // 最终降级到默认值 2.0 (Retina)
        return 2.0
    }
}
