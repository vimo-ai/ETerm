//
//  InfoWindowRegistry.swift
//  ETerm
//
//  信息窗口注册表 - 管理全局唯一的信息窗口

import SwiftUI
import AppKit
import Combine

/// 信息窗口内容项
struct InfoContent: Identifiable {
    let id: String
    let title: String
    let viewProvider: () -> AnyView
}

/// 信息窗口注册表 - 单例模式
final class InfoWindowRegistry: NSObject, ObservableObject, NSWindowDelegate {

    // MARK: - Singleton

    static let shared = InfoWindowRegistry()

    // MARK: - Properties

    /// 已注册的内容项
    @Published private(set) var registeredContents: [String: InfoContent] = [:]

    /// 当前可见的内容 ID 列表
    @Published private(set) var visibleContentIds: [String] = []

    /// 期望的窗口位置（选中文本的屏幕坐标）
    @Published var targetRect: NSRect = .zero

    /// 信息窗口实例（懒加载）
    private var infoWindow: InfoWindow?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private override init() {
        super.init()
        setupObservers()
        setupNotificationObservers()
    }

    private func setupObservers() {
        // 监听可见内容列表变化
        $visibleContentIds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.handleVisibleContentChange(ids)
            }
            .store(in: &cancellables)
    }

    private func setupNotificationObservers() {
        // 监听插件发来的位置设置请求
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.InfoPanelSetPosition"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rect = notification.userInfo?["rect"] as? NSRect else { return }
            self?.targetRect = rect
        }
    }

    // MARK: - Public API

    /// 注册内容
    /// - Parameters:
    ///   - id: 内容 ID（唯一标识）
    ///   - title: 内容标题
    ///   - viewProvider: 视图提供者
    func registerContent(id: String, title: String, viewProvider: @escaping () -> AnyView) {
        let content = InfoContent(id: id, title: title, viewProvider: viewProvider)
        registeredContents[id] = content
    }

    /// 注销内容
    /// - Parameter id: 内容 ID
    func unregisterContent(id: String) {
        registeredContents.removeValue(forKey: id)

        // 如果该内容正在显示，从可见列表移除
        if let index = visibleContentIds.firstIndex(of: id) {
            visibleContentIds.remove(at: index)
        }

    }

    /// 显示内容
    /// - Parameter id: 内容 ID
    func showContent(id: String) {
        guard registeredContents[id] != nil else {
            return
        }

        // 如果已经可见，不重复添加
        if visibleContentIds.contains(id) {
            return
        }

        // 添加到可见列表
        visibleContentIds.append(id)
    }

    /// 隐藏内容
    /// - Parameter id: 内容 ID
    func hideContent(id: String) {
        guard let index = visibleContentIds.firstIndex(of: id) else {
            return
        }

        visibleContentIds.remove(at: index)
    }

    /// 查询内容是否可见
    /// - Parameter id: 内容 ID
    /// - Returns: 是否可见
    func isContentVisible(id: String) -> Bool {
        return visibleContentIds.contains(id)
    }

    // MARK: - Private Methods

    private func handleVisibleContentChange(_ ids: [String]) {
        if ids.isEmpty {
            // 没有可见内容，关闭窗口
            closeWindow()
        } else {
            // 有可见内容，显示窗口
            showWindow()
        }
    }

    private func showWindow() {
        if infoWindow == nil {
            infoWindow = InfoWindow(registry: self)
            infoWindow?.delegate = self
        }
        infoWindow?.orderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 窗口关闭时清空可见内容列表
        visibleContentIds.removeAll()
    }

    private func closeWindow() {
        infoWindow?.orderOut(nil)
    }
}
