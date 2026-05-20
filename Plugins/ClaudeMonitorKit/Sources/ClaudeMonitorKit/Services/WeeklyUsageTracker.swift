//
//  WeeklyUsageTracker.swift
//  claude-helper
//
//  Created by 💻higuaifan on 2025/11/6.
//

import Foundation
import Combine

enum WeeklyUsageRecommendation: String {
    case accelerate
    case maintain
    case slowDown
    case pause
}

extension WeeklyUsageRecommendation {
    var displayName: String {
        switch self {
        case .accelerate: return "需要加速使用"
        case .maintain: return "节奏合理"
        case .slowDown: return "放慢节奏"
        case .pause: return "已达到周限"
        }
    }
}

struct WeeklyUsageSnapshot {
    struct Window {
        let utilization: Double      // 百分比 0-100
        let startDate: Date
        let endDate: Date
    }

    let overall: Window
    let opus: Window?
    let fiveHour: Window?
    let timeProgress: Double         // 0-1
    let usageProgress: Double        // 0-1
    let recommendation: WeeklyUsageRecommendation
    let recommendationReason: String
    let lastUpdated: Date
}

final class WeeklyUsageTracker: ObservableObject {
    static let shared = WeeklyUsageTracker()

    @Published private(set) var snapshot: WeeklyUsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private static let rateLimitsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.vimo/rate-limits.json"
    }()

    private var timer: Timer?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.higuaifan.claude-helper.weekly-usage", qos: .utility)

    private init() {
        refresh()
        startFileMonitor()
        startTimer()
    }

    deinit {
        timer?.invalidate()
        fileMonitor?.cancel()
    }

    func refresh(force: Bool = false) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isLoading { return }

            self.updateLoadingState(isLoading: true, error: nil)

            do {
                let localData = try self.readLocalRateLimits()
                guard let sevenDay = localData.sevenDay else {
                    throw TrackerError.missingWindow
                }

                let snapshot = try self.makeSnapshot(
                    from: sevenDay,
                    fiveHourWindow: localData.fiveHour
                )

                DispatchQueue.main.async {
                    self.snapshot = snapshot
                    self.isLoading = false
                    self.lastError = nil

                    UsageHistoryStore.shared.record(
                        utilization: snapshot.overall.utilization,
                        fiveHourUtilization: snapshot.fiveHour?.utilization,
                        opusUtilization: snapshot.opus?.utilization
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Local file reading

    private func readLocalRateLimits() throws -> LocalRateLimits {
        let url = URL(fileURLWithPath: Self.rateLimitsPath)

        guard FileManager.default.fileExists(atPath: Self.rateLimitsPath) else {
            throw TrackerError.fileNotFound
        }

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(LocalRateLimitsFile.self, from: data)

        let staleThreshold: TimeInterval = 3600
        let age = (Double(Date().timeIntervalSince1970) - Double(decoded.updatedAt) / 1000.0)
        if age > staleThreshold {
            throw TrackerError.staleData(seconds: Int(age))
        }

        return LocalRateLimits(
            sevenDay: decoded.sevenDay.map { w in
                UsageWindow(utilization: w.utilization, resetsAt: Date(timeIntervalSince1970: Double(w.resetsAt)))
            },
            fiveHour: decoded.fiveHour.map { w in
                UsageWindow(utilization: w.utilization, resetsAt: Date(timeIntervalSince1970: Double(w.resetsAt)))
            }
        )
    }

    // MARK: - File monitoring

    private func startFileMonitor() {
        let path = Self.rateLimitsPath
        let dir = (path as NSString).deletingLastPathComponent

        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.refresh()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
    }

    // MARK: - Timer fallback

    private func startTimer() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func updateLoadingState(isLoading: Bool, error: String?) {
        DispatchQueue.main.async {
            self.isLoading = isLoading
            self.lastError = error
        }
    }

    // MARK: - Snapshot building

    private func makeSnapshot(from window: UsageWindow,
                              fiveHourWindow: UsageWindow?) throws -> WeeklyUsageSnapshot {
        guard let endDate = window.resetsAt else {
            throw TrackerError.invalidWindow
        }
        guard let startDate = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -7, to: endDate) else {
            throw TrackerError.invalidWindow
        }

        let now = Date()
        let duration = endDate.timeIntervalSince(startDate)
        let elapsed = now.timeIntervalSince(startDate)
        let timeProgress = max(0, min(1, elapsed / max(duration, 1)))

        let usageProgress = max(0, min(1, window.utilization / 100.0))
        let recommendation = recommend(usageProgress: usageProgress, timeProgress: timeProgress)
        let recommendationReason = buildReason(usageProgress: usageProgress,
                                               timeProgress: timeProgress)

        let overall = WeeklyUsageSnapshot.Window(
            utilization: window.utilization,
            startDate: startDate,
            endDate: endDate
        )

        let fiveHour: WeeklyUsageSnapshot.Window?
        if let window = fiveHourWindow,
           let end = window.resetsAt,
           let start = Calendar(identifier: .gregorian)
            .date(byAdding: .hour, value: -5, to: end) {
            fiveHour = WeeklyUsageSnapshot.Window(
                utilization: window.utilization,
                startDate: start,
                endDate: end
            )
        } else {
            fiveHour = nil
        }

        return WeeklyUsageSnapshot(
            overall: overall,
            opus: nil,
            fiveHour: fiveHour,
            timeProgress: timeProgress,
            usageProgress: usageProgress,
            recommendation: recommendation,
            recommendationReason: recommendationReason,
            lastUpdated: now
        )
    }

    private func recommend(usageProgress: Double,
                           timeProgress: Double) -> WeeklyUsageRecommendation {
        if usageProgress >= 0.999 {
            return .pause
        }

        let delta = usageProgress - timeProgress
        if abs(delta) < 0.001 {
            return .maintain
        } else if delta > 0 {
            return .slowDown
        } else {
            return .accelerate
        }
    }

    private func buildReason(usageProgress: Double,
                             timeProgress: Double) -> String {
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

    // MARK: - Models

    private struct LocalRateLimitsFile: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: Int
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let updatedAt: Int
    }

    private struct LocalRateLimits {
        let sevenDay: UsageWindow?
        let fiveHour: UsageWindow?
    }

    private struct UsageWindow {
        let utilization: Double
        let resetsAt: Date?
    }

    private enum TrackerError: LocalizedError {
        case fileNotFound
        case staleData(seconds: Int)
        case missingWindow
        case invalidWindow

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "等待 Claude Code statusline 写入用量数据（~/.vimo/rate-limits.json）"
            case .staleData(let seconds):
                return "用量数据已过期（\(seconds / 60)分钟前更新），等待 Claude Code 会话刷新"
            case .missingWindow:
                return "用量文件中无七日窗口数据"
            case .invalidWindow:
                return "七日用量窗口数据不完整"
            }
        }
    }
}
