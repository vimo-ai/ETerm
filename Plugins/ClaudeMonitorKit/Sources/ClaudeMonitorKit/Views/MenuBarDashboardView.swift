//
//  MenuBarDashboardView.swift
//  ETerm - ClaudeMonitor Plugin
//
//  菜单栏弹出窗口内容 - 显示周度使用概览
//

import SwiftUI

// MARK: - 主视图组件从 ContentView.swift 提取

struct WeeklyUsageCard: View {
    @ObservedObject private var tracker = WeeklyUsageTracker.shared
    @Binding var skipWeekends: Bool
    @Binding var skipSleep: Bool
    let sleepSchedule: SleepSchedule

    var body: some View {
        let snapshot = tracker.snapshot
        let now = Date()
        let metrics = snapshot.map {
            computeTimeMetrics(
                for: $0,
                now: now,
                skipWeekends: skipWeekends,
                skipSleep: skipSleep,
                sleepSchedule: sleepSchedule
            )
        }
        let subtitle = makeSubtitle(snapshot: snapshot, metrics: metrics)

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("周度使用节奏")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                HStack(spacing: 12) {
                    Toggle(isOn: $skipWeekends) {
                        Text("跳过周末")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .toggleStyle(.switch)
                    .help("跳过周末后，时间进度按工作日计算")

                    Toggle(isOn: $skipSleep) {
                        Text("跳过睡眠")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .toggleStyle(.switch)
                    .help("跳过睡眠时间（每天 3:00-9:00）")
                }
            }

            contentSection(snapshot: snapshot, metrics: metrics)
        }
        .padding(24)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(16)
    }

    @ViewBuilder
    private func contentSection(snapshot: WeeklyUsageSnapshot?, metrics: TimeMetrics?) -> some View {
        if tracker.isLoading && snapshot == nil {
            HStack(spacing: 8) {
                ProgressView()
                Text("加载周度数据…")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        } else if let error = tracker.lastError, snapshot == nil {
            Text("无法获取周度用量：\(error)")
                .font(.subheadline)
                .foregroundColor(.red)
        } else if let snapshot, let metrics {
            usageContent(for: snapshot, metrics: metrics)
        } else {
            Text("等待首次刷新…")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }

    private func usageContent(for snapshot: WeeklyUsageSnapshot, metrics: TimeMetrics) -> some View {
        var overlaySegments: [ProgressOverlaySegment] = []
        let weekendSegments = skipWeekends ? weekendOverlaySegments(for: snapshot) : []

        if skipWeekends {
            overlaySegments.append(contentsOf: weekendSegments)
        }
        if skipSleep {
            overlaySegments.append(
                contentsOf: sleepOverlaySegments(
                    for: snapshot,
                    excluding: weekendSegments,
                    schedule: sleepSchedule
                )
            )
        }

        let arrowMarkers = makeArrowMarkers(snapshot: snapshot, metrics: metrics)

        return VStack(alignment: .leading, spacing: 16) {
            CapsuleProgressRow(
                title: {
                    var title = "时间进度"
                    if skipWeekends || skipSleep {
                        title += "（"
                        if skipWeekends { title += "跳过周末" }
                        if skipWeekends && skipSleep { title += "、" }
                        if skipSleep { title += "跳过睡眠" }
                        title += "）"
                    }
                    return title
                }(),
                valueText: formattedTimeProgress(metrics),
                progress: metrics.progress,
                tint: colorForTime(metrics.progress),
                overlaySegments: overlaySegments,
                arrowMarkers: arrowMarkers
            )

            // 显示剩余需要跳过的统计信息
            if skipWeekends || skipSleep {
                HStack(spacing: 12) {
                    if skipWeekends && metrics.hasRemainingWeekend {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.minus")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("剩余包含周末")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    if skipSleep && metrics.remainingSleepCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.caption2)
                                .foregroundColor(.purple)
                            Text("剩余跳过 \(metrics.remainingSleepCount) 次睡眠")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: recommendationIcon(snapshot.recommendation))
                        .foregroundColor(recommendationColor(snapshot.recommendation))
                    Text(snapshot.recommendation.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                }

                // 使用当前的时间进度(考虑跳过睡眠/周末)重新计算推荐理由
                Text(buildDynamicReason(usageProgress: snapshot.usageProgress, timeProgress: metrics.progress))
                    .font(.caption)
                    .foregroundColor(.gray)

                Text("更新于 \(formatUpdateTime(snapshot.lastUpdated))")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }

    private func formattedTimeProgress(_ metrics: TimeMetrics) -> String {
        let naturalText = String(format: "%.1f%%", metrics.progress * 100)
        if let effective = metrics.effectiveProgress {
            return naturalText + String(format: "（有效 %.1f%%）", effective * 100)
        }
        return naturalText
    }

    private func makeArrowMarkers(snapshot: WeeklyUsageSnapshot, metrics: TimeMetrics) -> [ProgressArrowMarker] {
        var markers: [ProgressArrowMarker] = []

        markers.append(
            ProgressArrowMarker(
                fraction: snapshot.usageProgress,
                label: String(format: "使用 %.1f%%", snapshot.usageProgress * 100),
                color: colorForUsage(snapshot.usageProgress)
            )
        )

        if let effective = metrics.effectiveProgress {
            markers.append(
                ProgressArrowMarker(
                    fraction: effective,
                    label: String(format: "有效 %.1f%%", effective * 100),
                    color: Color.purple
                )
            )
        }

        return markers
    }

    private func sleepOverlaySegments(for snapshot: WeeklyUsageSnapshot,
                                      excluding weekendSegments: [ProgressOverlaySegment],
                                      schedule: SleepSchedule) -> [ProgressOverlaySegment] {
        let start = snapshot.overall.startDate
        let end = snapshot.overall.endDate
        let totalSeconds = end.timeIntervalSince(start)
        guard totalSeconds > 0 else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var segments: [ProgressOverlaySegment] = []
        var dayStart = calendar.startOfDay(for: start)

        while dayStart < end {
            let intervals = sleepIntervals(forDayStarting: dayStart, schedule: schedule, calendar: calendar)
            for interval in intervals {
                let clippedStart = max(interval.start, start)
                let clippedEnd = min(interval.end, end)

                if clippedStart < clippedEnd {
                    let startFraction = clippedStart.timeIntervalSince(start) / totalSeconds
                    let endFraction = clippedEnd.timeIntervalSince(start) / totalSeconds
                    let overlapsWeekend = weekendSegments.contains { weekendSegment in
                        weekendSegment.clampedStart <= startFraction &&
                        weekendSegment.clampedEnd >= endFraction
                    }

                    if !overlapsWeekend {
                        segments.append(
                            ProgressOverlaySegment(
                                startFraction: startFraction,
                                endFraction: endFraction,
                                color: Color.purple.opacity(0.35)
                            )
                        )
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }
            dayStart = nextDay
        }

        return segments
    }


    private func weekendOverlaySegments(for snapshot: WeeklyUsageSnapshot) -> [ProgressOverlaySegment] {
        let start = snapshot.overall.startDate
        let end = snapshot.overall.endDate
        let totalSeconds = end.timeIntervalSince(start)
        guard totalSeconds > 0 else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var segments: [ProgressOverlaySegment] = []
        var dayStart = calendar.startOfDay(for: start)

        while dayStart < end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let weekday = calendar.component(.weekday, from: dayStart)
            let isWeekend = (weekday == 1 || weekday == 7)

            if isWeekend {
                let clippedStart = max(dayStart, start)
                let clippedEnd = min(nextDay, end)
                if clippedStart < clippedEnd {
                    let startFraction = clippedStart.timeIntervalSince(start) / totalSeconds
                    let endFraction = clippedEnd.timeIntervalSince(start) / totalSeconds
                    segments.append(
                        ProgressOverlaySegment(
                            startFraction: startFraction,
                            endFraction: endFraction,
                            color: Color.green.opacity(0.3)
                        )
                    )
                }
            }

            dayStart = nextDay
        }

        return segments
    }

    private func makeSubtitle(snapshot: WeeklyUsageSnapshot?, metrics: TimeMetrics?) -> String {
        if let snapshot, let metrics {
            let resetTime = formatResetTime(snapshot.overall.endDate)

            if skipWeekends || skipSleep {
                var suffix = "（"
                if skipWeekends { suffix += "跳过周末" }
                if skipWeekends && skipSleep { suffix += "、" }
                if skipSleep { suffix += "跳过睡眠" }
                suffix += "）"
                return "剩余工作时间 \(formatDuration(metrics.remainingSeconds))\(suffix)，\(resetTime)刷新"
            } else {
                let remaining = max(snapshot.overall.endDate.timeIntervalSince(Date()), 0)
                return "剩余 \(formatDuration(remaining))，\(resetTime)刷新"
            }
        } else if tracker.isLoading {
            return "正在刷新周度用量…"
        } else if let error = tracker.lastError {
            return "无法获取周度用量：\(error)"
        } else {
            return "等待首次刷新…"
        }
    }
}

struct HourlyUsageCard: View {
    let window: WeeklyUsageSnapshot.Window

    private var progress: Double {
        min(max(window.utilization / 100, 0), 1)
    }

    private var remainingText: String {
        let remaining = max(window.endDate.timeIntervalSince(Date()), 0)
        return "剩余 \(formatDuration(remaining)) · \(formatResetTime(window.endDate)) 重置"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("5 小时使用节奏")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(remainingText)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                Text(String(format: "%.1f%%", window.utilization))
                    .font(.headline)
                    .foregroundColor(.white)
            }

            CapsuleProgressRow(
                title: "小时进度",
                valueText: String(format: "%.1f%%", window.utilization),
                progress: progress,
                tint: .orange
            )
        }
        .padding(24)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(16)
    }
}

// MARK: - 辅助函数

private func buildDynamicReason(usageProgress: Double, timeProgress: Double) -> String {
    let usagePercent = usageProgress * 100
    let timePercent = timeProgress * 100
    let delta = usagePercent - timePercent

    let deltaText: String
    if abs(delta) < 1 {
        deltaText = "与时间进度基本一致"
    } else if delta > 0 {
        deltaText = String(format: "比时间进度快 %.1f%%", delta)
    } else {
        deltaText = String(format: "比时间进度慢 %.1f%%", abs(delta))
    }

    return String(format: "已使用 %.1f%%，时间进度 %.1f%%，%@", usagePercent, timePercent, deltaText)
}

private func colorForUsage(_ progress: Double) -> Color {
    let clamped = min(max(progress, 0), 1)
    let baseHue: Double = 0.33 // green
    let saturation = 0.25 + 0.70 * clamped
    let brightness = 0.92 - 0.45 * clamped
    return Color(hue: baseHue, saturation: saturation, brightness: brightness)
}

private func colorForTime(_ progress: Double) -> Color {
    let clamped = min(max(progress, 0), 1)
    let baseHue: Double = 0.58 // blue
    let saturation = 0.30 + 0.60 * clamped
    let brightness = 0.90 - 0.40 * clamped
    return Color(hue: baseHue, saturation: saturation, brightness: brightness)
}

// MARK: - 数据模型

private struct TimeMetrics {
    let progress: Double
    let effectiveProgress: Double?
    let remainingSeconds: TimeInterval
    let totalSeconds: TimeInterval
    let remainingSleepCount: Int
    let hasRemainingWeekend: Bool
}

struct SleepSchedule {
    var startMinutes: Int
    var durationMinutes: Int

    private var sanitizedStartMinutes: Int {
        max(0, min(startMinutes, 23 * 60 + 59))
    }

    private var sanitizedDurationMinutes: Int {
        max(1, min(durationMinutes, 24 * 60))
    }

    var startSeconds: Int { sanitizedStartMinutes * 60 }
    var durationSeconds: Int { sanitizedDurationMinutes * 60 }
    var isFullDay: Bool { sanitizedDurationMinutes >= 24 * 60 }
}

private struct ProgressOverlaySegment: Identifiable {
    let id = UUID()
    let startFraction: Double
    let endFraction: Double
    let color: Color

    var clampedStart: Double {
        min(max(startFraction, 0), 1)
    }

    var clampedEnd: Double {
        min(max(endFraction, 0), 1)
    }

    var widthFraction: Double {
        max(clampedEnd - clampedStart, 0)
    }
}

struct SleepInterval {
    let start: Date
    let end: Date
    let isPrimaryDay: Bool
}

private struct ProgressArrowMarker: Identifiable {
    let id = UUID()
    let fraction: Double
    let label: String
    let color: Color

    var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }
}

private func sleepIntervals(forDayStarting dayStart: Date,
                            schedule: SleepSchedule,
                            calendar: Calendar) -> [SleepInterval] {
    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
    guard schedule.durationSeconds > 0 else { return [] }

    if schedule.isFullDay {
        return [SleepInterval(start: dayStart, end: nextDay, isPrimaryDay: true)]
    }

    var results: [SleepInterval] = []
    let anchors: [(Date, Bool)] = [
        (dayStart, true),
        (calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart, false)
    ]

    for (anchor, isPrimary) in anchors {
        guard let intervalStart = calendar.date(byAdding: .second, value: schedule.startSeconds, to: anchor) else { continue }
        let intervalEnd = intervalStart.addingTimeInterval(TimeInterval(schedule.durationSeconds))
        let overlapStart = max(intervalStart, dayStart)
        let overlapEnd = min(intervalEnd, nextDay)
        if overlapStart < overlapEnd {
            results.append(SleepInterval(start: overlapStart, end: overlapEnd, isPrimaryDay: isPrimary))
        }
    }

    return results
}

private func computeTimeMetrics(for snapshot: WeeklyUsageSnapshot,
                                now: Date,
                                skipWeekends: Bool,
                                skipSleep: Bool,
                                sleepSchedule: SleepSchedule) -> TimeMetrics {
    let start = snapshot.overall.startDate
    let end = snapshot.overall.endDate
    let clampedNow = min(max(now, start), end)

    let totalNaturalSeconds = max(end.timeIntervalSince(start), 0)
    let elapsedNaturalSeconds = max(clampedNow.timeIntervalSince(start), 0)
    let naturalProgress = totalNaturalSeconds > 0 ? min(max(elapsedNaturalSeconds / totalNaturalSeconds, 0), 1) : 0

    if skipWeekends || skipSleep {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        let remainingResult = workingSeconds(
            from: clampedNow,
            to: end,
            skipWeekends: skipWeekends,
            skipSleep: skipSleep,
            sleepSchedule: sleepSchedule,
            calendar: calendar
        )

        let effectiveTotalResult = workingSeconds(
            from: start,
            to: end,
            skipWeekends: skipWeekends,
            skipSleep: skipSleep,
            sleepSchedule: sleepSchedule,
            calendar: calendar
        )
        let elapsedEffective = effectiveTotalResult.seconds - remainingResult.seconds
        let effectiveProgress = effectiveTotalResult.seconds > 0
            ? min(max(elapsedEffective / effectiveTotalResult.seconds, 0), 1)
            : nil

        return TimeMetrics(
            progress: naturalProgress,
            effectiveProgress: effectiveProgress,
            remainingSeconds: remainingResult.seconds,
            totalSeconds: totalNaturalSeconds,
            remainingSleepCount: remainingResult.skippedSleepCount,
            hasRemainingWeekend: remainingResult.skippedWeekendDays > 0
        )
    } else {
        let remaining = max(totalNaturalSeconds - elapsedNaturalSeconds, 0)
        return TimeMetrics(
            progress: naturalProgress,
            effectiveProgress: nil,
            remainingSeconds: remaining,
            totalSeconds: totalNaturalSeconds,
            remainingSleepCount: 0,
            hasRemainingWeekend: false
        )
    }
}

private struct WorkingSecondsResult {
    let seconds: TimeInterval
    let skippedSleepCount: Int
    let skippedWeekendDays: Int
}

private func workingSeconds(from start: Date,
                            to end: Date,
                            skipWeekends: Bool,
                            skipSleep: Bool,
                            sleepSchedule: SleepSchedule,
                            calendar: Calendar) -> WorkingSecondsResult {
    guard start < end else {
        return WorkingSecondsResult(seconds: 0, skippedSleepCount: 0, skippedWeekendDays: 0)
    }

    var total: TimeInterval = 0
    var current = start
    var skippedSleepCount = 0
    var skippedWeekendDays = 0

    while current < end {
        let dayStart = calendar.startOfDay(for: current)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

        let intervalStart = max(current, dayStart)
        let intervalEnd = min(end, nextDay)
        let weekday = calendar.component(.weekday, from: dayStart)

        let isWeekend = (weekday == 1 || weekday == 7)
        if skipWeekends && isWeekend {
            skippedWeekendDays += 1
            current = nextDay
            continue
        }

        var daySeconds = max(intervalEnd.timeIntervalSince(intervalStart), 0)

        if skipSleep && daySeconds > 0 {
            let intervals = sleepIntervals(forDayStarting: dayStart, schedule: sleepSchedule, calendar: calendar)
            var skippedToday = false

            for interval in intervals {
                let overlapStart = max(intervalStart, interval.start)
                let overlapEnd = min(intervalEnd, interval.end)

                if overlapStart < overlapEnd {
                    let overlapSeconds = overlapEnd.timeIntervalSince(overlapStart)
                    daySeconds -= overlapSeconds
                    if interval.isPrimaryDay {
                        skippedToday = true
                    }
                }
            }

            if skippedToday {
                skippedSleepCount += 1
            }
        }

        total += max(daySeconds, 0)
        current = nextDay
    }

    return WorkingSecondsResult(
        seconds: total,
        skippedSleepCount: skippedSleepCount,
        skippedWeekendDays: skippedWeekendDays
    )
}

private func recommendationColor(_ recommendation: WeeklyUsageRecommendation) -> Color {
    switch recommendation {
    case .accelerate: return .orange
    case .maintain: return .green
    case .slowDown: return .yellow
    case .pause: return .red
    }
}

private func recommendationIcon(_ recommendation: WeeklyUsageRecommendation) -> String {
    switch recommendation {
    case .accelerate: return "bolt.fill"
    case .maintain: return "checkmark.circle.fill"
    case .slowDown: return "tortoise.fill"
    case .pause: return "pause.circle.fill"
    }
}

private func formatUpdateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

private func formatResetTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds), 0)
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60

    if days > 0 {
        return "\(days)天\(hours)小时"
    } else if hours > 0 {
        return "\(hours)小时\(minutes)分钟"
    } else if minutes > 0 {
        return "\(minutes)分钟"
    } else {
        return "不到 1 分钟"
    }
}

// MARK: - 胶囊进度条

private struct CapsuleProgressRow: View {
    let title: String
    let valueText: String
    let progress: Double
    let tint: Color
    let overlaySegments: [ProgressOverlaySegment]
    let arrowMarkers: [ProgressArrowMarker]

    init(
        title: String,
        valueText: String,
        progress: Double,
        tint: Color,
        overlaySegments: [ProgressOverlaySegment] = [],
        arrowMarkers: [ProgressArrowMarker] = []
    ) {
        self.title = title
        self.valueText = valueText
        self.progress = progress
        self.tint = tint
        self.overlaySegments = overlaySegments
        self.arrowMarkers = arrowMarkers
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                Spacer()
                Text(valueText)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                VStack(spacing: arrowMarkers.isEmpty ? 0 : 6) {
                    if !arrowMarkers.isEmpty {
                        ZStack(alignment: .leading) {
                            ForEach(arrowMarkers) { marker in
                                let tipX = markerTipX(for: marker, totalWidth: width)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.caption2)
                                    .foregroundColor(marker.color)
                                    .position(x: tipX, y: 16)
                                Text(marker.label)
                                    .font(.caption2)
                                    .foregroundColor(marker.color)
                                    .position(
                                        x: markerLabelX(for: marker, tipX: tipX, totalWidth: width),
                                        y: 4
                                    )
                            }
                        }
                        .frame(height: 24)
                    }

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 6)
                        Capsule()
                            .fill(tint)
                            .frame(width: width * CGFloat(clampedProgress), height: 6)
                        ForEach(overlaySegments) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(
                                    width: width * CGFloat(segment.widthFraction),
                                    height: 6
                                )
                                .offset(x: width * CGFloat(segment.clampedStart))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: arrowMarkers.isEmpty ? 6 : 34)
        }
    }

    private func markerTipX(for marker: ProgressArrowMarker, totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(marker.clampedFraction)
    }

    private func markerLabelX(for marker: ProgressArrowMarker, tipX: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let padding: CGFloat = 10
        let base = tipX + padding
        let minX: CGFloat = padding
        let maxX = max(totalWidth - padding, minX)
        return min(max(base, minX), maxX)
    }
}
