//
//  ClaudeMonitorDashboardView.swift
//  ETerm - ClaudeMonitor Plugin
//
//  InfoWindow 显示的周度使用监控面板
//

import SwiftUI
import ETermKit

struct ClaudeMonitorDashboardView: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared
    @AppStorage("WeeklyUsageSkipWeekends") private var skipWeekends = false
    @AppStorage("WeeklyUsageSkipSleep") private var skipSleep = false
    @AppStorage("SleepStartMinutes") private var sleepStartMinutes = 180
    @AppStorage("SleepDurationMinutes") private var sleepDurationMinutes = 360
    @AppStorage("ShowHourlyUsageCard") private var showHourlyUsageCard = true
    @AppStorage("ShowUsageHistoryChart") private var showUsageHistoryChart = true
    @AppStorage("ShowSprintPrediction") private var showSprintPrediction = true

    private var sleepSchedule: SleepSchedule {
        SleepSchedule(
            startMinutes: sleepStartMinutes,
            durationMinutes: sleepDurationMinutes
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                WeeklyUsageCard(
                    skipWeekends: $skipWeekends,
                    skipSleep: $skipSleep,
                    sleepSchedule: sleepSchedule
                )

                AutoResumeCard()

                if showHourlyUsageCard, let fiveHour = tracker.snapshot?.fiveHour {
                    HourlyUsageCard(window: fiveHour)
                }

                if showUsageHistoryChart {
                    UsageHistoryChart()
                }

                if showSprintPrediction {
                    SprintPredictionView()
                }
            }
            .padding(12)
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}

// MARK: - Auto Resume Card

struct AutoResumeCard: View {
    @ObservedObject private var autoResume = AutoResumeService.shared
    @ObservedObject private var tracker = WeeklyUsageTracker.shared
    @AppStorage("AutoResumeEnabled") private var autoResumeEnabled = false
    @State private var showManualPicker = false
    @State private var manualDate = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(autoResumeEnabled ? ThemeColors.UI.success : ThemeColors.UI.textMuted)

                VStack(alignment: .leading, spacing: 2) {
                    Text("自动拉起")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textPrimary)
                    Text("周限重置后自动启动 Claude")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $autoResumeEnabled)
                    .toggleStyle(.switch)
                    .tint(Color(ThemeColors.accent))
                    .labelsHidden()
            }

            if autoResumeEnabled {
                if let date = autoResume.scheduledDate {
                    scheduledRow(date: date)
                } else if tracker.snapshot?.recommendation == .pause {
                    Text("已触发限额，等待调度…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.warning)
                } else {
                    Text("未达限额，无需调度")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textMuted)
                }

                manualScheduleRow()
            }
        }
        .padding(20)
        .background(ThemeColors.UI.bgCard)
        .cornerRadius(12)
    }

    private func scheduledRow(date: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundColor(ThemeColors.UI.success)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(date, style: .date) \(date, style: .time) 拉起")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textPrimary)
                Text(autoResume.scheduleSource == .manual ? "手动设定" : "自动检测")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textSecondary)
            }

            Spacer()

            Button("取消") {
                autoResume.cancel()
            }
            .font(.system(size: 11, design: .monospaced))
            .buttonStyle(.borderless)
            .foregroundColor(ThemeColors.UI.error)
        }
    }

    @ViewBuilder
    private func manualScheduleRow() -> some View {
        if showManualPicker {
            HStack(spacing: 8) {
                DatePicker("", selection: $manualDate, in: Date()...)
                    .labelsHidden()

                Button("确定") {
                    autoResume.scheduleManual(at: manualDate)
                    showManualPicker = false
                }
                .font(.system(size: 11, design: .monospaced))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("取消") {
                    showManualPicker = false
                }
                .font(.system(size: 11, design: .monospaced))
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        } else {
            Button {
                manualDate = Date().addingTimeInterval(3600)
                showManualPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.plus")
                        .font(.caption)
                    Text("手动设定时间")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .buttonStyle(.borderless)
            .foregroundColor(ThemeColors.UI.accent)
        }
    }
}
