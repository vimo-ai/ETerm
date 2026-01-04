//
//  ClaudeUsageTabView.swift
//  ClaudeMonitorKit
//
//  Claude 用量监控 - PageBar 组件

import SwiftUI
import ETermKit

/// Claude 用量 PageBar 组件
struct ClaudeUsageTabView: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared

    /// 用于控制 InfoPanel 显示/隐藏
    var onToggleDashboard: (() -> Void)?

    /// ETerm 主题色（青绿色 #2AD98D）
    private let themeAccentColor = Color(red: 0x2A/255.0, green: 0xD9/255.0, blue: 0x8D/255.0)

    /// 根据用量与时间进度的偏差计算时间进度条颜色（HSB 渐变）
    /// 目标是用完配额：用量领先=好（蓝→绿），用量落后=危险（黄→橙→红）
    private var timeProgressColor: Color {
        guard let snapshot = tracker.snapshot else {
            return .gray
        }

        // 差值 = 用量进度 - 时间进度
        // 正数 = 用得快（好），负数 = 用得慢（危险）
        let delta = snapshot.usageProgress - snapshot.timeProgress

        // 将 delta 映射到色相：
        // delta >= +0.20 → 蓝色 (hue=0.58)
        // delta == 0     → 绿色 (hue=0.33)
        // delta <= -0.20 → 红色 (hue=0.0)
        let clampedDelta = min(max(delta, -0.20), 0.20)
        let normalized = (clampedDelta + 0.20) / 0.40  // 0.0 ~ 1.0

        // 色相从红(0) → 绿(0.33) → 蓝(0.58)
        let hue: Double
        if normalized <= 0.5 {
            // 红 → 绿
            hue = normalized * 2 * 0.33
        } else {
            // 绿 → 蓝
            hue = 0.33 + (normalized - 0.5) * 2 * 0.25
        }

        // 饱和度和亮度（柔和但可辨识）
        let saturation = 0.50
        let brightness = 0.75

        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        Button(action: { onToggleDashboard?() }) {
            HStack(spacing: 6) {
                // 双进度条
                VStack(spacing: 2) {
                    // 时间进度条（动态颜色：红→绿→蓝）
                    UsageProgressBarView(
                        progress: tracker.snapshot?.timeProgress ?? 0,
                        color: timeProgressColor
                    )
                    .frame(width: 32, height: 3)

                    // 用量进度条（主题色）
                    UsageProgressBarView(
                        progress: tracker.snapshot?.usageProgress ?? 0,
                        color: themeAccentColor
                    )
                    .frame(width: 32, height: 3)
                }

                // 百分比
                Text(usageText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(tracker.snapshot != nil ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(tracker.snapshot?.recommendationReason ?? "Claude 用量监控")
    }

    private var usageText: String {
        guard let snapshot = tracker.snapshot else {
            return "--%"
        }
        return String(format: "%.0f%%", snapshot.overall.utilization)
    }
}

// MARK: - Progress Bar View

private struct UsageProgressBarView: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.3))

                // 进度
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, progress))))
            }
        }
    }
}
