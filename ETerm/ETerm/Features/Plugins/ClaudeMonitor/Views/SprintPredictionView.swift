//
//  claude-helper
//
//  Created by claude-helper on 2025/11/23.
//

import SwiftUI

/// 冲刺预测视图
/// 显示最近 5 次用量变化的时间间隔，并预测按每个速率用完剩余额度需要多久
struct SprintPredictionView: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared
    @ObservedObject private var historyStore = UsageHistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题区域
            headerSection

            // 预测内容
            contentSection
        }
        .padding(16)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
    }

    // MARK: - 标题区域

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title3)
                .foregroundColor(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text("冲刺预测")
                    .font(.headline)
                    .foregroundColor(.white)

                if let snapshot = tracker.snapshot {
                    let remainingPercent = 100 - snapshot.overall.utilization
                    let remainingTime = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0)
                    Text("剩余 \(formatPercent(remainingPercent))，\(formatDurationCompact(remainingTime))")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    Text("等待数据...")
                        .font(.caption)
                        .foregroundColor(.gray)
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
                    // 加权平均预测（主预测）
                    if let weighted = weightedPrediction {
                        weightedPredictionView(weighted)
                    }

                    // 分隔线
                    Divider()
                        .background(Color.gray.opacity(0.3))

                    // 详细列表
                    predictionsListView(predictions: predictions)
                }
            }
        }
    }

    // MARK: - 加权平均预测视图

    @ViewBuilder
    private func weightedPredictionView(_ prediction: WeightedPrediction) -> some View {
        HStack(spacing: 12) {
            // 状态指示
            Text(prediction.status.emoji)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                // 主预测结果
                HStack(spacing: 6) {
                    Text("综合预测")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)

                    Text("(\(prediction.sampleCount)个样本)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // 预测时间和差值
                HStack(spacing: 8) {
                    Text(formatPredictedTime(prediction.predictedFinishTime))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(formatDelta(prediction.delta))
                        .font(.subheadline)
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
                .font(.subheadline)
                .foregroundColor(.gray)
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
            // 采集时间
            Text(formatTimestamp(prediction.interval.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.cyan)
                .frame(width: 45, alignment: .leading)

            // 变化区间
            Text(formatIntervalRange(prediction.interval))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 70, alignment: .leading)

            // 耗时
            Text(formatDurationCompact(prediction.interval.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 50, alignment: .trailing)

            // 箭头
            Text("->")
                .font(.caption)
                .foregroundColor(.gray)

            // 预测用完时间
            Text(formatPredictedTime(prediction.predictedFinishTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 60, alignment: .trailing)

            // 状态标识和差值
            HStack(spacing: 4) {
                Text(prediction.status.emoji)
                    .font(.caption2)
                Text(formatDelta(prediction.delta))
                    .font(.caption)
                    .foregroundColor(deltaColor(prediction.status))
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(rowBackground(prediction.status))
        .cornerRadius(6)
    }

    // MARK: - 格式化方法

    /// 格式化时间戳，显示为 "HH:mm"
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 格式化变化区间，如 "73%->74%"
    private func formatIntervalRange(_ interval: ConsumptionInterval) -> String {
        String(format: "%.0f%%->%.0f%%", interval.fromUtilization, interval.toUtilization)
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

    /// 差值颜色
    private func deltaColor(_ status: SprintStatus) -> Color {
        switch status {
        case .surplus: return .green
        case .balanced: return .yellow
        case .deficit: return .red
        }
    }

    /// 行背景色
    private func rowBackground(_ status: SprintStatus) -> Color {
        switch status {
        case .surplus: return Color.green.opacity(0.1)
        case .balanced: return Color.yellow.opacity(0.1)
        case .deficit: return Color.red.opacity(0.1)
        }
    }
}

#Preview {
    SprintPredictionView()
        .frame(width: 400)
        .padding()
        .background(Color.black)
}
