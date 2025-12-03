//
//  MenuBarController.swift
//  ETerm
//
//  Claude Monitor 菜单栏控制器
//

import SwiftUI
import AppKit
import Combine

class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let weeklyTracker = WeeklyUsageTracker.shared

    init() {}

    func setup() {
        setupMenuBar()
        observeUsageChanges()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 90)
        
        guard let button = statusItem?.button else {
            print("❌ 无法创建状态栏按钮")
            return
        }
        
        setupCustomView(in: button)
        button.target = self
        button.action = #selector(toggleInfoWindow(_:))
        button.setAccessibilityElement(true)
        button.setAccessibilityLabel("Claude Weekly Monitor")
    }
    
    private func setupCustomView(in button: NSStatusBarButton) {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        
        let timeProgressView = CustomProgressView(frame: NSRect(x: 4, y: 13, width: 45, height: 3))
        timeProgressView.identifier = NSUserInterfaceItemIdentifier("timeProgress")
        containerView.addSubview(timeProgressView)
        
        let usageProgressView = CustomProgressView(frame: NSRect(x: 4, y: 7, width: 45, height: 3))
        usageProgressView.identifier = NSUserInterfaceItemIdentifier("usageProgress")
        containerView.addSubview(usageProgressView)
        
        let label = NSTextField(frame: NSRect(x: 53, y: 6, width: 35, height: 12))
        label.identifier = NSUserInterfaceItemIdentifier("usageLabel")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.isBezeled = false
        label.isEditable = false
        label.backgroundColor = .clear
        label.alignment = .center
        label.stringValue = "--%"
        containerView.addSubview(label)
        
        button.addSubview(containerView)
    }
    
    private func observeUsageChanges() {
        weeklyTracker.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarDisplay()
            }
            .store(in: &cancellables)
        
        weeklyTracker.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarDisplay()
            }
            .store(in: &cancellables)
    }
    
    private func updateMenuBarDisplay() {
        guard let button = statusItem?.button,
              let containerView = button.subviews.first else {
            return
        }
        
        let timeProgressView = containerView.subviews.first {
            $0.identifier?.rawValue == "timeProgress"
        } as? CustomProgressView
        
        let usageProgressView = containerView.subviews.first {
            $0.identifier?.rawValue == "usageProgress"
        } as? CustomProgressView
        
        let label = containerView.subviews.first {
            $0.identifier?.rawValue == "usageLabel"
        } as? NSTextField
        
        guard let snapshot = weeklyTracker.snapshot else {
            timeProgressView?.updateProgress(0, color: .systemGray)
            usageProgressView?.updateProgress(0, color: .systemGray)
            label?.stringValue = "--%"
            label?.textColor = .secondaryLabelColor
            return
        }
        
        timeProgressView?.updateProgress(snapshot.timeProgress, color: .systemBlue)
        
        let usageColor: NSColor
        switch snapshot.recommendation {
        case .accelerate:
            usageColor = .systemBlue
        case .maintain:
            usageColor = .systemGreen
        case .slowDown:
            usageColor = .systemOrange
        case .pause:
            usageColor = .systemRed
        }
        
        usageProgressView?.updateProgress(snapshot.usageProgress, color: usageColor)
        label?.stringValue = String(format: "%.0f%%", snapshot.overall.utilization)
        label?.textColor = .labelColor
    }
    
    @objc private func toggleInfoWindow(_ sender: AnyObject?) {
        // 切换 InfoWindow 显示状态
        let contentId = "claude-monitor-dashboard"

        if InfoWindowRegistry.shared.isContentVisible(id: contentId) {
            InfoWindowRegistry.shared.hideContent(id: contentId)
        } else {
            InfoWindowRegistry.shared.showContent(id: contentId)
        }
    }

    func cleanup() {
        cancellables.removeAll()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }
}
