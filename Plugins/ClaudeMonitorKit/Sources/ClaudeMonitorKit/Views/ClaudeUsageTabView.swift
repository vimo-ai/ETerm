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

    private var usageColor: Color {
        guard let snapshot = tracker.snapshot else {
            return .gray
        }
        switch snapshot.recommendation {
        case .accelerate: return .blue
        case .maintain: return .green
        case .slowDown: return .orange
        case .pause: return .red
        }
    }

    var body: some View {
        Button(action: { onToggleDashboard?() }) {
            HStack(spacing: 6) {
                // 双进度条
                VStack(spacing: 2) {
                    // 时间进度条
                    UsageProgressBarView(
                        progress: tracker.snapshot?.timeProgress ?? 0,
                        color: .blue
                    )
                    .frame(width: 32, height: 3)

                    // 用量进度条
                    UsageProgressBarView(
                        progress: tracker.snapshot?.usageProgress ?? 0,
                        color: usageColor
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
