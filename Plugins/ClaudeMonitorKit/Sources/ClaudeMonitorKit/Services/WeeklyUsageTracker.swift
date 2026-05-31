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
    case sprinting
    case waitingForReset
    case wavesInsufficient
}

extension WeeklyUsageRecommendation {
    var displayName: String {
        switch self {
        case .accelerate: return "需要加速使用"
        case .maintain: return "节奏合理"
        case .slowDown: return "放慢节奏"
        case .pause: return "已达到周限"
        case .sprinting: return "冲刺中"
        case .waitingForReset: return "等待 5h 重置"
        case .wavesInsufficient: return "波次不足"
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
    let waveProjection: WaveProjectionResult?
}

final class WeeklyUsageTracker: ObservableObject {
    static let shared = WeeklyUsageTracker()
    
    @Published private(set) var snapshot: WeeklyUsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.higuaifan.claude-helper.weekly-usage", qos: .utility)
    
    private init() {
        refresh(force: true)
        startTimer()
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func refresh(force: Bool = false) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isLoading && !force { return }
            
            self.updateLoadingState(isLoading: true, error: nil)
            
            do {
                let accessToken = try self.fetchAccessTokenFromKeychain()
                let usageResponse = try self.fetchUsage(accessToken: accessToken)
                guard let weeklyWindow = usageResponse.sevenDay else {
                    throw TrackerError.missingWindow
                }
                
                let snapshot = try self.makeSnapshot(from: weeklyWindow,
                                                     opusWindow: usageResponse.sevenDayOpus,
                                                     fiveHourWindow: usageResponse.fiveHour)
                
                DispatchQueue.main.async {
                    self.snapshot = snapshot
                    self.isLoading = false
                    self.lastError = nil

                    // 记录用量历史数据点
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
    
    // MARK: - Private helpers
    
    private func startTimer() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
    
    private func fetchAccessTokenFromKeychain() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-a", NSUserName(),
            "-s", "Claude Code-credentials",
            "-w"
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "无法读取Keychain凭据"
            throw TrackerError.keychain(message)
        }
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw TrackerError.keychain("Keychain未返回任何数据")
        }
        
        guard let jsonString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let jsonData = jsonString.data(using: .utf8) else {
            throw TrackerError.keychain("Keychain数据格式不正确")
        }
        
        let decoder = JSONDecoder()
        let credentials = try decoder.decode(KeychainCredentialEnvelope.self, from: jsonData)
        return credentials.claudeAiOauth.accessToken
    }
    
    private func fetchUsage(accessToken: String) throws -> OAuthUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw TrackerError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()
        
        semaphore.wait()
        
        if let error = responseError {
            throw error
        }
        
        guard let data = responseData else {
            throw TrackerError.emptyResponse
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.isoFormatterWithFractional.date(from: value) {
                return date
            }
            if let date = Self.isoFormatter.date(from: value) {
                return date
            }
            throw TrackerError.invalidDate(value)
        }
        
        return try decoder.decode(OAuthUsageResponse.self, from: data)
    }
    
    private func makeSnapshot(from window: UsageWindow,
                              opusWindow: UsageWindow?,
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

        let overall = WeeklyUsageSnapshot.Window(
            utilization: window.utilization,
            startDate: startDate,
            endDate: endDate
        )
        
        let opus: WeeklyUsageSnapshot.Window?
        if let opusWindow = opusWindow, let opusEnd = opusWindow.resetsAt,
           let opusStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -7, to: opusEnd) {
            opus = WeeklyUsageSnapshot.Window(
                utilization: opusWindow.utilization,
                startDate: opusStart,
                endDate: opusEnd
            )
        } else {
            opus = nil
        }
        
        let fiveHour: WeeklyUsageSnapshot.Window?
        if let fhWindow = fiveHourWindow,
           let end = fhWindow.resetsAt,
           let start = Calendar(identifier: .gregorian)
            .date(byAdding: .hour, value: -5, to: end) {
            fiveHour = WeeklyUsageSnapshot.Window(
                utilization: fhWindow.utilization,
                startDate: start,
                endDate: end
            )
        } else {
            fiveHour = nil
        }

        // 波次投影
        var waveProjection: WaveProjectionResult?
        if let fhWindow = fiveHourWindow,
           let fhResetDate = fhWindow.resetsAt {
            waveProjection = SprintPredictor.shared.generateWaveProjection(
                sdUsed: window.utilization,
                sdResetDate: endDate,
                fhUsed: fhWindow.utilization,
                fhResetDate: fhResetDate
            )
        }

        let recommendation = recommend(
            usageProgress: usageProgress,
            timeProgress: timeProgress,
            fhUtilization: fiveHourWindow?.utilization,
            waveProjection: waveProjection
        )
        let recommendationReason = buildReason(
            usageProgress: usageProgress,
            timeProgress: timeProgress,
            waveProjection: waveProjection
        )

        return WeeklyUsageSnapshot(
            overall: overall,
            opus: opus,
            fiveHour: fiveHour,
            timeProgress: timeProgress,
            usageProgress: usageProgress,
            recommendation: recommendation,
            recommendationReason: recommendationReason,
            lastUpdated: now,
            waveProjection: waveProjection
        )
    }

    private func recommend(
        usageProgress: Double,
        timeProgress: Double,
        fhUtilization: Double?,
        waveProjection: WaveProjectionResult?
    ) -> WeeklyUsageRecommendation {
        if usageProgress >= 0.999 {
            return .pause
        }
        if let fh = fhUtilization, fh >= 99 {
            return .waitingForReset
        }
        if let wave = waveProjection {
            switch wave.status {
            case .sprinting: return .sprinting
            case .wavesInsufficient: return .wavesInsufficient
            case .waitingForReset: return .waitingForReset
            case .completed: return .pause
            case .onTrack: return .maintain
            case .speedInsufficient: return .accelerate
            case .noSpeedData: break
            }
        }
        // fallback 到旧线性逻辑
        let delta = usageProgress - timeProgress
        if abs(delta) < 0.001 { return .maintain }
        else if delta > 0 { return .slowDown }
        else { return .accelerate }
    }

    private func buildReason(
        usageProgress: Double,
        timeProgress: Double,
        waveProjection: WaveProjectionResult?
    ) -> String {
        let usagePercent = usageProgress * 100
        let timePercent = timeProgress * 100

        if let wave = waveProjection {
            let projected = Int(wave.projectedSdAtReset)
            switch wave.status {
            case .sprinting:
                return "冲刺中：终\(projected)%，波\(wave.currentWaveIndex)/\(wave.wavesNeeded)"
            case .waitingForReset:
                return "5h 窗口已满，等待重置"
            case .wavesInsufficient:
                return "剩余波次不足，最多打到 \(projected)%"
            case .speedInsufficient:
                return "当前速度不足，需加速。终\(projected)%，波\(wave.currentWaveIndex)/\(wave.wavesNeeded)"
            case .onTrack:
                return "进度正常：终\(projected)%，波\(wave.currentWaveIndex)/\(wave.wavesNeeded)"
            case .completed:
                return "已达到周限"
            case .noSpeedData:
                return "等待速度数据..."
            }
        }

        let delta = usagePercent - timePercent
        if abs(delta) < 1 {
            return String(format: "已使用 %.1f%%，与时间进度基本一致", usagePercent)
        } else if delta > 0 {
            return String(format: "已使用 %.1f%%，比时间进度快 %.1f%%", usagePercent, delta)
        } else {
            return String(format: "已使用 %.1f%%，比时间进度慢 %.1f%%", usagePercent, abs(delta))
        }
    }
    
    // MARK: - Supporting models
    
    private struct KeychainCredentialEnvelope: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
        }
        let claudeAiOauth: OAuth
    }
    
    private struct OAuthUsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDayOauthApps: UsageWindow?
        let iguanaNecktie: UsageWindow?
    }
    
    private struct UsageWindow: Decodable {
        let utilization: Double
        let resetsAt: Date?
    }
    
    private enum TrackerError: LocalizedError {
        case keychain(String)
        case invalidURL
        case emptyResponse
        case invalidDate(String)
        case missingWindow
        case invalidWindow
        
        var errorDescription: String? {
            switch self {
            case .keychain(let message):
                return "Keychain 读取失败: \(message)"
            case .invalidURL:
                return "用量接口地址无效"
            case .emptyResponse:
                return "用量接口未返回任何数据"
            case .invalidDate(let value):
                return "无法解析日期: \(value)"
            case .missingWindow:
                return "未返回七日用量窗口"
            case .invalidWindow:
                return "七日用量窗口数据不完整"
            }
        }
    }
    
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
