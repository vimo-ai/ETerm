//
//  claude-helper
//
//  Created by claude-helper on 2025/11/23.
//

import SwiftUI
import ETermKit

/// 冲刺预测视图
/// 显示最近 5 次用量变化的时间间隔，并预测按每个速率用完剩余额度需要多久
struct SprintPredictionView: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared
    @ObservedObject private var historyStore = UsageHistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            contentSection
        }
        .padding(16)
        .background(ThemeColors.UI.bgCard)
        .cornerRadius(12)
    }

    // MARK: - 标题区域

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.UI.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("冲刺预测")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textPrimary)

                if let snapshot = tracker.snapshot {
                    let remainingPercent = 100 - snapshot.overall.utilization
                    let remainingTime = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0)
                    Text("剩余 \(formatPercent(remainingPercent))，\(formatDurationCompact(remainingTime))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                } else {
                    Text("AWAITING DATA...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textMuted)
                }
            }

            Spacer()
        }
    }

    // MARK: - 内容区域

    @ViewBuilder
    private var contentSection: some View {
        if tracker.snapshot == nil {
            emptyStateView(message: "等待首次刷新...")
        } else if let snapshot = tracker.snapshot {
            let remainingPercent = 100 - snapshot.overall.utilization
            let remainingTime = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0)
            let predictions = SprintPredictor.shared.generatePredictions(
                remainingPercent: remainingPercent,
                remainingTime: remainingTime
            )
            let weightedPrediction = SprintPredictor.shared.generateWeightedPrediction(
                remainingPercent: remainingPercent,
                remainingTime: remainingTime
            )

            if predictions.isEmpty {
                emptyStateView(message: "暂无足够数据")
            } else {
                VStack(spacing: 12) {
                    if let weighted = weightedPrediction {
                        weightedPredictionView(weighted)
                    }

                    Rectangle()
                        .fill(ThemeColors.UI.border)
                        .frame(height: 1)

                    predictionsListView(predictions: predictions)
                }
            }
        }
    }

    // MARK: - 加权平均预测视图

    @ViewBuilder
    private func weightedPredictionView(_ prediction: WeightedPrediction) -> some View {
        HStack(spacing: 12) {
            Text(prediction.status.emoji)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("综合预测")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)

                    Text("\(prediction.sampleCount)个样本")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textMuted)
                }

                HStack(spacing: 8) {
                    Text(formatPredictedTime(prediction.predictedFinishTime))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textPrimary)

                    Text(formatDelta(prediction.delta))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(deltaColor(prediction.status))
                }
            }

            Spacer()
        }
        .padding(12)
        .background(rowBackground(prediction.status).opacity(2))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func emptyStateView(message: String) -> some View {
        HStack {
            Spacer()
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textMuted)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func predictionsListView(predictions: [SprintPrediction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(predictions) { prediction in
                predictionRow(prediction)
            }
        }
    }

    // MARK: - 单行预测

    @ViewBuilder
    private func predictionRow(_ prediction: SprintPrediction) -> some View {
        HStack(spacing: 8) {
            Text(formatIntervalRange(prediction.interval))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textMuted)
                .frame(width: 65, alignment: .leading)

            Text(formatTimeRange(prediction.interval))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textPrimary)
                .frame(width: 95, alignment: .leading)

            Text(formatDurationCompact(prediction.interval.duration))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.accent)
                .frame(width: 55, alignment: .trailing)

            Spacer()

            Text(formatPredictedTime(prediction.predictedFinishTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textSecondary)
                .frame(width: 60, alignment: .trailing)

            Text(formatDelta(prediction.delta))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(deltaColor(prediction.status))
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowBackground(prediction.status))
        .cornerRadius(4)
    }

    // MARK: - 格式化方法

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatTimeRange(_ interval: ConsumptionInterval) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let end = interval.timestamp
        let start = end.addingTimeInterval(-interval.duration)
        return "\(fmt.string(from: start))→\(fmt.string(from: end))"
    }

    private func formatIntervalRange(_ interval: ConsumptionInterval) -> String {
        String(format: "%.0f%%→%.0f%%", interval.fromUtilization, interval.toUtilization)
    }

    /// 格式化百分比
    private func formatPercent(_ percent: Double) -> String {
        String(format: "%.0f%%", percent)
    }

    /// 格式化紧凑时长（分钟/小时自动切换）
    private func formatDurationCompact(_ seconds: TimeInterval) -> String {
        if seconds < 3600 {
            // 小于 1 小时，显示分钟
            let minutes = max(1, Int(seconds / 60))
            return "\(minutes)分钟"
        } else {
            // >= 1 小时，显示小时（保留 1 位小数）
            let hours = seconds / 3600
            return String(format: "%.1fh", hours)
        }
    }

    /// 格式化预测用完时间
    private func formatPredictedTime(_ seconds: TimeInterval) -> String {
        if seconds < 3600 {
            let minutes = max(1, Int(seconds / 60))
            return "\(minutes)分钟用完"
        } else {
            let hours = seconds / 3600
            return String(format: "%.1fh用完", hours)
        }
    }

    /// 格式化差值（富余/超出）
    private func formatDelta(_ delta: TimeInterval) -> String {
        let absDelta = abs(delta)
        let timeStr: String

        if absDelta < 3600 {
            let minutes = max(1, Int(absDelta / 60))
            timeStr = "\(minutes)分钟"
        } else {
            let hours = absDelta / 3600
            timeStr = String(format: "%.1fh", hours)
        }

        if delta > 0 {
            return "富余\(timeStr)"
        } else {
            return "超出\(timeStr)"
        }
    }

    private func deltaColor(_ status: SprintStatus) -> Color {
        switch status {
        case .surplus: return ThemeColors.UI.success
        case .balanced: return ThemeColors.UI.warning
        case .deficit: return ThemeColors.UI.error
        }
    }

    private func rowBackground(_ status: SprintStatus) -> Color {
        switch status {
        case .surplus: return ThemeColors.UI.success.opacity(0.08)
        case .balanced: return ThemeColors.UI.warning.opacity(0.08)
        case .deficit: return ThemeColors.UI.error.opacity(0.08)
        }
    }
}

#Preview {
    SprintPredictionView()
        .frame(width: 400)
        .padding()
        .background(ThemeColors.UI.bgPrimary)
}
