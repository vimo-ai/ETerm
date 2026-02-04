//
//  ClaudeMonitorPlugin.swift
//  ClaudeMonitorKit
//
//  Claude Monitor Plugin - 监控 Claude Code 使用情况

import Foundation
import AppKit
import SwiftUI
import Combine
import ETermKit

/// Claude 监控插件 - 提供周度使用节奏、冲刺预测等功能
@objc(ClaudeMonitorPlugin)
public final class ClaudeMonitorPlugin: NSObject, ETermKit.Plugin {
    public static let id = "com.eterm.claude-monitor"

    /// 主应用桥接
    private var host: (any HostBridge)?

    /// Dashboard 是否可见
    private var isDashboardVisible = false

    // MARK: - 初始化

    public override required init() {
        super.init()
    }

    // MARK: - Plugin 协议

    public func activate(host: any HostBridge) {
        self.host = host

        // 初始化周度用量追踪器（自动开始刷新）
        _ = WeeklyUsageTracker.shared

        // 初始化用量历史存储
        _ = UsageHistoryStore.shared

        // 初始化自动拉起服务
        AutoResumeService.shared.configure(host: host)
    }

    public func deactivate() {
        AutoResumeService.shared.stop()
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 暂无事件处理
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令处理
    }

    // MARK: - UI 提供

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "claude-monitor-settings" else { return nil }
        return AnyView(ClaudeMonitorSettingsView())
    }

    public func infoPanelView(for id: String) -> AnyView? {
        guard id == "claude-monitor-dashboard" else { return nil }
        return AnyView(ClaudeMonitorDashboardView())
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        guard itemId == "claude-usage-tab" else { return nil }
        return AnyView(
            ClaudeUsageTabView(onToggleDashboard: { [weak self] in
                self?.toggleDashboard()
            })
        )
    }

    // MARK: - Private

    private func toggleDashboard() {
        isDashboardVisible.toggle()
        if isDashboardVisible {
            host?.showInfoPanel("claude-monitor-dashboard")
        } else {
            host?.hideInfoPanel("claude-monitor-dashboard")
        }
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
    @AppStorage("AutoResumeEnabled") private var autoResumeEnabled = false
    @ObservedObject private var autoResume = AutoResumeService.shared
    @State private var manualDate = Date()
    @State private var showManualPicker = false

    var body: some View {
        Form {
            Section("自动拉起") {
                Toggle("周限重置自动拉起 Claude", isOn: $autoResumeEnabled)
                    .help("周限打满后，到重置时间自动创建终端并启动 Claude 会话")

                if let date = autoResume.scheduledDate {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("将于 \(date, style: .date) \(date, style: .time) 拉起")
                                    .font(.callout)
                                Text(autoResume.scheduleSource == .manual ? "手动设定" : "自动检测")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "timer")
                                .foregroundStyle(.green)
                        }

                        Spacer()

                        Button("取消") {
                            autoResume.cancel()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    if showManualPicker {
                        DatePicker("", selection: $manualDate, in: Date()...)
                            .labelsHidden()

                        Button("确定") {
                            autoResume.scheduleManual(at: manualDate)
                            showManualPicker = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("取消") {
                            showManualPicker = false
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    } else {
                        Button("手动设定时间") {
                            manualDate = Date().addingTimeInterval(3600)
                            showManualPicker = true
                        }
                    }
                }
            }

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
