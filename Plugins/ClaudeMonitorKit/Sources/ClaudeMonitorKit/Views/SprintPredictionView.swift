import SwiftUI
import ETermKit

struct SprintPredictionView: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题区域
            headerSection
            if let snapshot = tracker.snapshot {
                if let wave = snapshot.waveProjection {
                    waveContent(wave, snapshot: snapshot)
                } else {
                    legacyFallback(snapshot: snapshot)
                }
            } else {
                emptyState("等待首次刷新...")
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
    }

    // MARK: - Header

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
                    let remaining = 100 - snapshot.overall.utilization
                    let hoursLeft = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0) / 3600
                    let timeStr = hoursLeft >= 24
                        ? String(format: "%.0fd%.0fh", floor(hoursLeft / 24), hoursLeft.truncatingRemainder(dividingBy: 24))
                        : String(format: "%.0fh", hoursLeft)
                    Text("剩余 \(Int(remaining))%, \(timeStr)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Wave content

    @ViewBuilder
    private func waveContent(_ wave: WaveProjectionResult, snapshot: WeeklyUsageSnapshot) -> some View {
        heroView(wave)

        Rectangle()
            .fill(ThemeColors.UI.border)
            .frame(height: 1)

        waveList(wave)

        if wave.projectedSdAtReset < 99.5 {
            ceilingWarning(projected: wave.projectedSdAtReset)
        }
    }

    // MARK: - Hero: 终X% 波N/M 速度对比

    @ViewBuilder
    private func heroView(_ wave: WaveProjectionResult) -> some View {
        HStack(spacing: 16) {
            // 终 X%
            let projected = Int(wave.projectedSdAtReset)
            let projColor = projected >= 100 ? ThemeColors.UI.success :
                            projected >= 90  ? ThemeColors.UI.warning : ThemeColors.UI.error
            Text("终\(projected)%")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(projColor)

            // 波 N/M + 预计完成时间
            VStack(alignment: .leading, spacing: 2) {
                let waveColor = wave.currentWaveIndex <= wave.wavesNeeded
                    ? ThemeColors.UI.warning : ThemeColors.UI.success
                Text("波\(wave.currentWaveIndex)/\(wave.wavesNeeded)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(waveColor)

                if let finish = wave.projectedFinishTime {
                    Text("完\(formatTime(finish))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.info)
                }
            }

            Spacer()

            // 速度对比
            if let speed = wave.currentSpeed {
                let actual = Int(speed)
                let target = Int(wave.targetSpeed)
                let isFast = speed <= wave.targetSpeed
                HStack(spacing: 4) {
                    Text("速\(actual)")
                        .foregroundColor(isFast ? ThemeColors.UI.success : ThemeColors.UI.error)
                    Text(isFast ? "快" : "慢")
                        .foregroundColor(isFast ? ThemeColors.UI.success : ThemeColors.UI.error)
                    Text("要\(target)")
                        .foregroundColor(ThemeColors.UI.textMuted)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            } else {
                Text("等待速度数据")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
            }
        }
        .padding(12)
        .background(heroBackground(wave))
        .cornerRadius(8)
    }

    private func heroBackground(_ wave: WaveProjectionResult) -> Color {
        if wave.projectedSdAtReset >= 99.5 {
            return ThemeColors.UI.success.opacity(0.08)
        } else if wave.projectedSdAtReset >= 90 {
            return ThemeColors.UI.warning.opacity(0.08)
        }
        return ThemeColors.UI.error.opacity(0.08)
    }

    // MARK: - Wave list

    @ViewBuilder
    private func waveList(_ wave: WaveProjectionResult) -> some View {
        if wave.waves.isEmpty {
            emptyState("无波次数据")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(wave.waves) { w in
                    waveRow(w, currentSpeed: wave.currentSpeed, targetSpeed: wave.targetSpeed)
                }
            }
        }
    }

    @ViewBuilder
    private func waveRow(
        _ w: WaveProjection,
        currentSpeed: Double?,
        targetSpeed: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // 波号 + 当前标记
                HStack(spacing: 4) {
                    Text("波\(w.id)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textPrimary)
                    if w.isCurrentWave {
                        Text("当前")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(ThemeColors.UI.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ThemeColors.UI.accent.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                .frame(width: 70, alignment: .leading)

                // 时间窗口
                Text("\(formatTime(w.startTime))→\(formatTime(w.endTime))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textSecondary)

                Spacer()

                // 烧了多少 7d%
                let burnStr = String(format: "+%.1f%%", w.sdBurnPercent)
                Text(burnStr)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.accent)

                // 是否撞天花板
                if w.hitFhCeiling {
                    Text("满")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(ThemeColors.UI.warning)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(ThemeColors.UI.warning.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            // 当前波额外显示速度信息
            if w.isCurrentWave, let speed = currentSpeed {
                let actual = Int(speed)
                let target = Int(targetSpeed)
                let isFast = speed <= targetSpeed
                let label = isFast ? "快于目标" : "慢于目标"
                let color = isFast ? ThemeColors.UI.success : ThemeColors.UI.error
                Text("  速度 \(actual)分/1%  \(label) \(target)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(w.isCurrentWave ? ThemeColors.UI.accent.opacity(0.05) : Color.clear)
        .cornerRadius(4)
    }

    // MARK: - Ceiling warning

    @ViewBuilder
    private func ceilingWarning(projected: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(ThemeColors.UI.error)
            Text("波次不足：最多打到 \(Int(projected))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(ThemeColors.UI.error)
            Spacer()
        }
        .padding(10)
        .background(ThemeColors.UI.error.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Legacy fallback

    @ViewBuilder
    private func legacyFallback(snapshot: WeeklyUsageSnapshot) -> some View {
        let remaining = 100 - snapshot.overall.utilization
        let remainingTime = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0)
        let weighted = SprintPredictor.shared.generateWeightedPrediction(
            remainingPercent: remaining,
            remainingTime: remainingTime
        )
        if let w = weighted {
            HStack(spacing: 12) {
                Text(w.status.emoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("综合预测（线性）")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                    Text(formatDuration(w.predictedFinishTime))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textPrimary)
                }
                Spacer()
            }
            .padding(12)
            .background(ThemeColors.UI.bgTertiary)
            .cornerRadius(8)
        } else {
            emptyState("暂无足够数据")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func emptyState(_ message: String) -> some View {
        HStack {
            Spacer()
            Text(message)
                .font(.subheadline)
                .foregroundColor(.gray)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 {
            return "\(max(1, Int(seconds / 60)))分钟"
        }
        return String(format: "%.1fh", seconds / 3600)
    }
}

#Preview {
    SprintPredictionView()
        .frame(width: 400)
        .padding()
        .background(Color.black)
}
