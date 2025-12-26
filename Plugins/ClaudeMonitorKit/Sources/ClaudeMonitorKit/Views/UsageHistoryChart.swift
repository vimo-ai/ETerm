//
//  UsageHistoryChart.swift
//  ClaudeMonitorKit
//
//  用量历史曲线图组件

import SwiftUI
import Charts

/// 用量历史曲线图组件
struct UsageHistoryChart: View {
    @ObservedObject private var historyStore = UsageHistoryStore.shared
    @ObservedObject private var weeklyTracker = WeeklyUsageTracker.shared

    // 读取跳过设置
    @AppStorage("WeeklyUsageSkipWeekends") private var skipWeekends = false
    @AppStorage("WeeklyUsageSkipSleep") private var skipSleep = false
    @AppStorage("SleepStartMinutes") private var sleepStartMinutes = 180  // 默认 3:00
    @AppStorage("SleepDurationMinutes") private var sleepDurationMinutes = 360  // 默认 6 小时

    /// 当前周期的数据点
    private var currentCycleData: [UsageDataPoint] {
        historyStore.currentCycleDataPoints
    }

    /// 周期起始时间
    private var cycleStartDate: Date? {
        weeklyTracker.snapshot?.overall.startDate
    }

    /// 周期结束时间
    private var cycleEndDate: Date? {
        weeklyTracker.snapshot?.overall.endDate
    }

    /// 理想进度线数据点（考虑跳过周末/睡眠）
    private var idealProgressData: [(Date, Double)] {
        guard let startDate = cycleStartDate,
              let endDate = cycleEndDate else { return [] }

        // 如果没有跳过设置，返回简单的直线
        if !skipWeekends && !skipSleep {
            return [(startDate, 0), (endDate, 100)]
        }

        // 生成分段的理想进度线
        return generateIdealProgressPoints(from: startDate, to: endDate)
    }

    /// 当前时间
    private var currentTime: Date { Date() }

    /// 当前时间是否在周期范围内
    private var isCurrentTimeInCycle: Bool {
        guard let startDate = cycleStartDate,
              let endDate = cycleEndDate else { return false }
        return currentTime >= startDate && currentTime <= endDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("用量趋势")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if let startDate = cycleStartDate, let endDate = cycleEndDate {
                    Text(formatCycleLabel(startDate, endDate: endDate))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            chartView
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Chart View

    private var chartView: some View {
        Chart {
            // 理想进度参考线（绿色虚线）
            ForEach(Array(idealProgressData.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("时间", point.0),
                    y: .value("理想", point.1),
                    series: .value("类型", "理想进度")
                )
                .foregroundStyle(Color.green.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            // 当前时间标记线
            if isCurrentTimeInCycle {
                RuleMark(x: .value("现在", currentTime))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    .annotation(position: .top, alignment: .center) {
                        Text("现在")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
            }

            // 实际用量曲线
            if !currentCycleData.isEmpty {
                ForEach(currentCycleData) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("用量", point.utilization),
                        series: .value("类型", "实际用量")
                    )
                    .foregroundStyle(Color.blue)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXScale(domain: xAxisDomain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 1)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatXAxisLabel(date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 120)
        .overlay(alignment: .center) {
            if currentCycleData.isEmpty && cycleStartDate != nil {
                Text("等待数据...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
            } else if cycleStartDate == nil {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("暂无周期数据")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var xAxisDomain: ClosedRange<Date> {
        if let startDate = cycleStartDate, let endDate = cycleEndDate {
            return startDate...endDate
        }
        let now = Date()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return sevenDaysAgo...now
    }

    // MARK: - Ideal Progress Calculation

    /// 生成考虑跳过周末/睡眠的理想进度点
    private func generateIdealProgressPoints(from startDate: Date, to endDate: Date) -> [(Date, Double)] {
        var points: [(Date, Double)] = []
        let calendar = Calendar.current

        // 计算总有效时间
        let totalEffectiveTime = calculateEffectiveTime(from: startDate, to: endDate)
        guard totalEffectiveTime > 0 else {
            return [(startDate, 0), (endDate, 100)]
        }

        // 每小时采样生成进度点
        var currentDate = startDate
        let hourInterval: TimeInterval = 3600

        while currentDate <= endDate {
            let effectiveElapsed = calculateEffectiveTime(from: startDate, to: currentDate)
            let progress = (effectiveElapsed / totalEffectiveTime) * 100
            points.append((currentDate, progress))

            currentDate = currentDate.addingTimeInterval(hourInterval)
        }

        // 确保终点
        if let lastPoint = points.last, lastPoint.0 < endDate {
            points.append((endDate, 100))
        }

        return points
    }

    /// 计算两个时间点之间的有效时间（秒）
    private func calculateEffectiveTime(from startDate: Date, to endDate: Date) -> TimeInterval {
        guard endDate > startDate else { return 0 }

        let calendar = Calendar.current
        var effectiveTime: TimeInterval = 0
        var currentDate = startDate

        // 按小时遍历
        let hourInterval: TimeInterval = 3600

        while currentDate < endDate {
            let nextDate = min(currentDate.addingTimeInterval(hourInterval), endDate)
            let segmentDuration = nextDate.timeIntervalSince(currentDate)

            // 检查是否应该跳过这个时段
            let shouldSkip = shouldSkipTime(at: currentDate, calendar: calendar)

            if !shouldSkip {
                effectiveTime += segmentDuration
            }

            currentDate = nextDate
        }

        return effectiveTime
    }

    /// 判断指定时间点是否应该跳过
    private func shouldSkipTime(at date: Date, calendar: Calendar) -> Bool {
        // 检查周末
        if skipWeekends {
            let weekday = calendar.component(.weekday, from: date)
            // 周日 = 1, 周六 = 7
            if weekday == 1 || weekday == 7 {
                return true
            }
        }

        // 检查睡眠时间
        if skipSleep {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let currentMinutes = hour * 60 + minute

            // 计算睡眠时间范围
            let sleepEnd = (sleepStartMinutes + sleepDurationMinutes) % 1440

            if sleepStartMinutes < sleepEnd {
                // 不跨午夜：例如 3:00 - 9:00
                if currentMinutes >= sleepStartMinutes && currentMinutes < sleepEnd {
                    return true
                }
            } else {
                // 跨午夜：例如 23:00 - 5:00
                if currentMinutes >= sleepStartMinutes || currentMinutes < sleepEnd {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Helpers

    private func formatCycleLabel(_ startDate: Date, endDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return "周期: \(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
    }

    private func formatXAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

#Preview {
    UsageHistoryChart()
        .frame(width: 320)
        .padding()
}
