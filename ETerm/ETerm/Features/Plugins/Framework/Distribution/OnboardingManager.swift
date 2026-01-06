//
//  OnboardingManager.swift
//  ETerm
//
//  首次启动引导管理
//

import Foundation
import Combine
import AppKit
import SwiftUI

/// 首次启动引导管理器
final class OnboardingManager: NSObject, ObservableObject {
    static let shared = OnboardingManager()

    /// UserDefaults key
    private static let hasSeenOnboardingKey = "hasSeenOnboarding"

    /// 是否已看过引导
    @Published private(set) var hasSeenOnboarding: Bool

    /// 是否正在显示引导
    @Published var isShowingOnboarding = false

    /// 引导窗口
    private var onboardingWindow: NSWindow?

    private override init() {
        self.hasSeenOnboarding = UserDefaults.standard.bool(forKey: Self.hasSeenOnboardingKey)
        super.init()
    }

    // MARK: - 公开方法

    /// 检查是否应该显示首次引导
    ///
    /// 条件：
    /// 1. 可下载插件未全部安装
    /// 2. 用户未标记为"已看过"
    func shouldShowOnboarding() -> Bool {
        // 1. 可下载插件全装了 → 不弹（没必要）
        if allDownloadablePluginsInstalled() {
            return false
        }

        // 2. 看过标记 → 不弹（用户主动跳过）
        if hasSeenOnboarding {
            return false
        }

        // 3. 首次 → 弹
        return true
    }

    /// 标记引导为已完成
    func markOnboardingComplete() {
        hasSeenOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.hasSeenOnboardingKey)
        closeOnboardingWindow()
    }

    /// 跳过引导（标记为已看过，但不安装）
    func skipOnboarding() {
        markOnboardingComplete()
    }

    /// 显示引导窗口
    func showOnboarding() {
        guard onboardingWindow == nil else { return }

        isShowingOnboarding = true

        // 创建引导窗口
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 ETerm"
        window.isReleasedWhenClosed = false
        window.center()

        // 设置窗口关闭回调
        window.delegate = self

        // 设置 SwiftUI 内容
        let contentView = OnboardingView(onboardingManager: self)
        window.contentView = NSHostingView(rootView: contentView)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    /// 关闭引导窗口
    private func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
        isShowingOnboarding = false
    }

    /// 重置引导状态（用于调试）
    func resetOnboardingState() {
        hasSeenOnboarding = false
        UserDefaults.standard.removeObject(forKey: Self.hasSeenOnboardingKey)
    }

    // MARK: - 私有方法

    /// 检查所有可下载插件是否已安装
    private func allDownloadablePluginsInstalled() -> Bool {
        let versionManager = VersionManager.shared

        // 检查 VlaudeKit 和 MemexKit
        let vlaudeInstalled = versionManager.isPluginInstalled("com.eterm.vlaude")
        let memexInstalled = versionManager.isPluginInstalled("com.eterm.memex")

        return vlaudeInstalled && memexInstalled
    }
}

// MARK: - NSWindowDelegate

extension OnboardingManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindow else {
            return
        }

        // 用户点击关闭按钮，视为跳过
        if !hasSeenOnboarding {
            hasSeenOnboarding = true
            UserDefaults.standard.set(true, forKey: Self.hasSeenOnboardingKey)
        }
        onboardingWindow = nil
        isShowingOnboarding = false
    }
}

// MARK: - 调试支持

#if DEBUG
extension OnboardingManager {
    /// 强制显示引导（调试用）
    func forceShowOnboarding() {
        resetOnboardingState()
        showOnboarding()
    }
}
#endif
