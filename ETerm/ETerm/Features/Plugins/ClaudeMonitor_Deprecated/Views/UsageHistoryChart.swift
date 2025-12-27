//
//  UsageHistoryChart.swift
//  claude-helper
//
//  Created by higuaifan on 2025/11/23.
//

import SwiftUI
import Charts

/// 用量历史曲线图组件
struct UsageHistoryChart: View {
    @ObservedObject private var historyStore = UsageHistoryStore.shared
    @ObservedObject private var weeklyTracker = WeeklyUsageTracker.shared

    /// 当前周期的数据点
    private var currentCycleData: [UsageDataPoint] {
        historyStore.currentCycleDataPoints
    }

    /// 周期起始时间（从 WeeklyUsageTracker 获取，确保是完整 7 天）
    private var cycleStartDate: Date? {
        weeklyTracker.snapshot?.overall.startDate
    }

    /// 周期结束时间（从 WeeklyUsageTracker 获取）
    private var cycleEndDate: Date? {
        weeklyTracker.snapshot?.overall.endDate
    }

    /// 理想进度线数据点（从周期起点到周期终点的直线）
    private var idealProgressData: [(Date, Double)] {
        guard let startDate = cycleStartDate,
              let endDate = cycleEndDate else { return [] }

        // 生成理想进度线：从 (startDate, 0%) 到 (endDate, 100%)
        return [
            (startDate, 0),
            (endDate, 100)
        ]
    }

    /// 当前时间（用于绘制垂直标记线）
    private var currentTime: Date {
        Date()
    }

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

    // MARK: - Subviews

    /// 图表视图（始终显示，即使没有数据也显示坐标轴和理想线）
    private var chartView: some View {
        Chart {
            // 理想进度参考线（绿色虚线，从 0% 到 100%）
            ForEach(idealProgressData, id: \.0) { date, value in
                LineMark(
                    x: .value("时间", date),
                    y: .value("理想", value),
                    series: .value("类型", "理想进度")
                )
                .foregroundStyle(Color.green.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            // 当前时间标记线（垂直虚线）
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

            // 实际用量曲线（平滑曲线）
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
            // 无数据时的提示覆盖层
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

    /// X 轴的范围（完整 7 天周期）
    private var xAxisDomain: ClosedRange<Date> {
        if let startDate = cycleStartDate, let endDate = cycleEndDate {
            return startDate...endDate
        }
        // 默认显示过去 7 天到现在
        let now = Date()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return sevenDaysAgo...now
    }

    // MARK: - Helpers

    /// 格式化周期标签
    private func formatCycleLabel(_ startDate: Date, endDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)

        return "周期: \(startStr) - \(endStr)"
    }

    /// 格式化X轴标签
    private func formatXAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    UsageHistoryChart()
        .frame(width: 320)
        .padding()
}
