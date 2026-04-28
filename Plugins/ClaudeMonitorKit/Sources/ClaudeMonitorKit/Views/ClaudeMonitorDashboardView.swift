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
