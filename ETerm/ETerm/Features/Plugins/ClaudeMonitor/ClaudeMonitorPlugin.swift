//
//  ClaudeMonitorPlugin.swift
//  ETerm
//
//  Claude Monitor Plugin - 监控 Claude Code 使用情况
//

import Foundation
import AppKit
import SwiftUI
import Combine

/// Claude 监控插件 - 提供周度使用节奏、冲刺预测、临时文件管理等功能
final class ClaudeMonitorPlugin: Plugin {
    static let id = "claude-monitor"
    static let name = "Claude 监控"
    static let version = "1.0.0"

    // MARK: - 私有属性

    /// 菜单栏控制器
    private var menuBarController: MenuBarController?

    /// 插件上下文
    private weak var context: PluginContext?

    // MARK: - 初始化

    required init() {}

    // MARK: - Plugin 协议

    func activate(context: PluginContext) {
        self.context = context


        // 1. 初始化周度用量追踪器（自动开始刷新）
        _ = WeeklyUsageTracker.shared

        // 2. 初始化用量历史存储
        _ = UsageHistoryStore.shared

        // 3. 注册 InfoWindow 内容
        registerInfoContent(context: context)

        // 4. 创建菜单栏
        setupMenuBar()

        // 5. 注册侧边栏 Tab（可选）
        registerSidebarTabs(context: context)

    }

    /// 注册信息窗口内容
    private func registerInfoContent(context: PluginContext) {
        context.ui.registerInfoContent(
            for: Self.id,
            id: "claude-monitor-dashboard",
            title: "Claude 监控"
        ) {
            AnyView(ClaudeMonitorDashboardView())
        }
    }

    func deactivate() {
        // 清理菜单栏
        menuBarController?.cleanup()
        menuBarController = nil

    }

    // MARK: - 私有方法

    /// 设置菜单栏
    private func setupMenuBar() {
        DispatchQueue.main.async {
            self.menuBarController = MenuBarController()
            self.menuBarController?.setup()
        }
    }

    /// 注册侧边栏 Tab
    private func registerSidebarTabs(context: PluginContext) {
        // 设置 Tab
        let settingsTab = SidebarTab(
            id: "claude-monitor-settings",
            title: "监控设置",
            icon: "gearshape.fill"
        ) {
            AnyView(ClaudeMonitorSettingsView())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: settingsTab)

    }
}

// MARK: - 设置视图

struct ClaudeMonitorSettingsView: View {
    @AppStorage("WeeklyUsageSkipWeekends") private var skipWeekends = false
    @AppStorage("WeeklyUsageSkipSleep") private var skipSleep = false
    @AppStorage("SleepStartMinutes") private var sleepStartMinutes = 180
    @AppStorage("SleepDurationMinutes") private var sleepDurationMinutes = 360
    @AppStorage("ShowHourlyUsageCard") private var showHourlyUsageCard = true
    @AppStorage("ShowUsageHistoryChart") private var showUsageHistoryChart = true
    @AppStorage("ShowSprintPrediction") private var showSprintPrediction = true

    var body: some View {
        Form {
            Section("时间计算设置") {
                Toggle("跳过周末", isOn: $skipWeekends)
                    .help("启用后，时间进度将排除周末（周六、周日）")

                Toggle("跳过睡眠时间", isOn: $skipSleep)
                    .help("启用后，时间进度将排除睡眠时间")

                if skipSleep {
                    HStack {
                        Text("睡眠开始时间:")
                        Spacer()
                        Text(formatMinutes(sleepStartMinutes))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(sleepStartMinutes) },
                        set: { sleepStartMinutes = Int($0) }
                    ), in: 0...1439, step: 30)

                    HStack {
                        Text("睡眠时长:")
                        Spacer()
                        Text("\(sleepDurationMinutes / 60) 小时")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(sleepDurationMinutes) },
                        set: { sleepDurationMinutes = Int($0) }
                    ), in: 60...720, step: 30)
                }
            }

            Section("显示设置") {
                Toggle("显示 5 小时用量卡片", isOn: $showHourlyUsageCard)
                Toggle("显示用量历史曲线", isOn: $showUsageHistoryChart)
                Toggle("显示冲刺预测", isOn: $showSprintPrediction)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 500)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d", hours, mins)
    }
}
