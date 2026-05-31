import Foundation

// MARK: - Legacy types (kept for fallback)

struct ConsumptionInterval: Identifiable {
    let id = UUID()
    let fromUtilization: Double
    let toUtilization: Double
    let duration: TimeInterval
    let timestamp: Date

    var timePerPercent: TimeInterval {
        let change = toUtilization - fromUtilization
        guard change > 0 else { return 0 }
        return duration / change
    }

    var percentChange: Double {
        toUtilization - fromUtilization
    }

    func predictTimeToFinish(remainingPercent: Double) -> TimeInterval {
        guard timePerPercent > 0, remainingPercent > 0 else { return 0 }
        return timePerPercent * remainingPercent
    }
}

enum SprintStatus {
    case surplus, balanced, deficit

    var emoji: String {
        switch self {
        case .surplus: return "🟢"
        case .balanced: return "🟡"
        case .deficit: return "🔴"
        }
    }
}

struct SprintPrediction: Identifiable {
    let id = UUID()
    let interval: ConsumptionInterval
    let predictedFinishTime: TimeInterval
    let remainingTime: TimeInterval
    let delta: TimeInterval

    var status: SprintStatus {
        if delta > 7200 { return .surplus }
        else if delta < -7200 { return .deficit }
        return .balanced
    }
}

struct WeightedPrediction {
    let predictedFinishTime: TimeInterval
    let remainingTime: TimeInterval
    let delta: TimeInterval
    let confidence: Double
    let sampleCount: Int

    var status: SprintStatus {
        if delta > 7200 { return .surplus }
        else if delta < -7200 { return .deficit }
        return .balanced
    }
}

// MARK: - Wave-aware types

/// 单波模拟结果
struct WaveProjection: Identifiable {
    let id: Int
    let startTime: Date
    let endTime: Date
    let sdBurnPercent: Double
    let fhConsumedPercent: Double
    let hitFhCeiling: Bool
    let isCurrentWave: Bool
}

/// 波次感知推荐状态
enum WaveAwareStatus {
    case sprinting
    case waitingForReset
    case onTrack
    case speedInsufficient
    case wavesInsufficient
    case noSpeedData
    case completed
}

/// 完整波次投影结果
struct WaveProjectionResult {
    let currentSpeed: Double?
    let projectedSdAtReset: Double
    let wavesNeeded: Int
    let currentWaveIndex: Int
    let waves: [WaveProjection]
    let targetSpeed: Double
    let status: WaveAwareStatus
    let projectedFinishTime: Date?  // 预计完成时间，打不到 100% 时为 nil
}

// MARK: - SprintPredictor

final class SprintPredictor {
    static let shared = SprintPredictor()
    private let weights: [Double] = [0.40, 0.25, 0.20, 0.10, 0.05]
    private init() {}

    // MARK: - Wave projection (primary API)

    func generateWaveProjection(
        sdUsed: Double, sdResetDate: Date,
        fhUsed: Double, fhResetDate: Date
    ) -> WaveProjectionResult? {
        guard sdUsed < 99.5 else {
            return WaveProjectionResult(
                currentSpeed: nil, projectedSdAtReset: 100,
                wavesNeeded: 0, currentWaveIndex: 0, waves: [],
                targetSpeed: 0, status: .completed,
                projectedFinishTime: nil
            )
        }

        guard let speed = UsageLogReader.readCurrentSpeed() else {
            return makeNoSpeedResult(
                sdUsed: sdUsed, sdResetDate: sdResetDate,
                fhUsed: fhUsed, fhResetDate: fhResetDate
            )
        }

        return simulateWaves(
            sdUsed: sdUsed, sdResetDate: sdResetDate,
            fhUsed: fhUsed, fhResetDate: fhResetDate,
            speed: speed
        )
    }

    // MARK: - Wave simulation

    private func simulateWaves(
        sdUsed: Double, sdResetDate: Date,
        fhUsed: Double, fhResetDate: Date,
        speed: Double
    ) -> WaveProjectionResult {
        let now = Date()
        let sdRemaining = 100 - sdUsed
        let fhRemaining = 100 - fhUsed
        let ratio = WaveConstants.sevenDayPerFullWave / 100 // 0.176

        // 当前波打满需要的速度
        let minutesLeftInWave = max(0, fhResetDate.timeIntervalSince(now) / 60)
        let sdNeededToFillWave = fhRemaining * ratio
        let targetSpeed = sdNeededToFillWave > 0
            ? minutesLeftInWave / sdNeededToFillWave
            : 0

        // 逐波模拟
        var totalSdBurned: Double = 0
        var waves: [WaveProjection] = []
        var simTime = now
        var simFhReset = fhResetDate
        var simFhRemaining = fhRemaining
        var finishTime: Date?

        while simTime < sdResetDate, totalSdBurned < sdRemaining {
            let waveNum = waves.count + 1
            let waveEnd = min(simFhReset, sdResetDate)
            let waveMinutes = max(0, waveEnd.timeIntervalSince(simTime) / 60)

            let sdByTime = waveMinutes / speed
            let sdByQuota = simFhRemaining * ratio
            let sdBurned = min(sdByTime, sdByQuota, sdRemaining - totalSdBurned)

            let fhConsumed: Double
            if ratio > 0 {
                fhConsumed = min(100, sdBurned / ratio)
            } else {
                fhConsumed = 0
            }

            waves.append(WaveProjection(
                id: waveNum,
                startTime: simTime,
                endTime: waveEnd,
                sdBurnPercent: sdBurned,
                fhConsumedPercent: fhConsumed,
                hitFhCeiling: sdByQuota <= sdByTime,
                isCurrentWave: waveNum == 1
            ))

            totalSdBurned += sdBurned

            // 这波烧完了，算精确完成时间
            if totalSdBurned >= sdRemaining, finishTime == nil {
                let minutesUsed = sdBurned * speed
                finishTime = simTime.addingTimeInterval(minutesUsed * 60)
            }

            simTime = simFhReset
            simFhReset = simFhReset.addingTimeInterval(WaveConstants.fiveHourWindowSeconds)
            simFhRemaining = 100
        }

        let projectedSd = min(100, sdUsed + totalSdBurned)

        let status = determineStatus(
            sdUsed: sdUsed,
            fhUsed: fhUsed,
            speed: speed,
            targetSpeed: targetSpeed,
            projectedSd: projectedSd,
            sdResetDate: sdResetDate,
            fhResetDate: fhResetDate
        )

        return WaveProjectionResult(
            currentSpeed: speed,
            projectedSdAtReset: projectedSd,
            wavesNeeded: waves.count,
            currentWaveIndex: 1,
            waves: waves,
            targetSpeed: targetSpeed,
            status: status,
            projectedFinishTime: finishTime
        )
    }

    private func determineStatus(
        sdUsed: Double,
        fhUsed: Double,
        speed: Double,
        targetSpeed: Double,
        projectedSd: Double,
        sdResetDate: Date,
        fhResetDate: Date
    ) -> WaveAwareStatus {
        if fhUsed >= 99 {
            return .waitingForReset
        }
        if projectedSd >= 99.5 {
            return speed <= targetSpeed ? .sprinting : .onTrack
        }
        // 按极限速度（1 min/1%）模拟，看是否物理上不可能到达 100%
        let maxResult = simulateWaves(
            sdUsed: sdUsed, sdResetDate: sdResetDate,
            fhUsed: fhUsed, fhResetDate: fhResetDate,
            speed: 1
        )
        if maxResult.projectedSdAtReset < 99.5 {
            return .wavesInsufficient
        }
        return .speedInsufficient
    }

    /// 无速度数据时：只能算波次上限（假设能打满每波）
    private func makeNoSpeedResult(
        sdUsed: Double, sdResetDate: Date,
        fhUsed: Double, fhResetDate: Date
    ) -> WaveProjectionResult {
        let now = Date()
        let sdRemaining = 100 - sdUsed
        let ratio = WaveConstants.sevenDayPerFullWave / 100

        // 计算可用波次数和理论最大产出
        var maxSdBurned: Double = 0
        var wavesAvailable = 0
        var simTime = now
        var simFhReset = fhResetDate
        var simFhRemaining = 100 - fhUsed

        while simTime < sdResetDate, maxSdBurned < sdRemaining {
            wavesAvailable += 1
            let sdByQuota = simFhRemaining * ratio
            maxSdBurned += min(sdByQuota, sdRemaining - maxSdBurned)

            simTime = simFhReset
            simFhReset = simFhReset.addingTimeInterval(WaveConstants.fiveHourWindowSeconds)
            simFhRemaining = 100
        }

        let maxProjected = min(100, sdUsed + maxSdBurned)
        let status: WaveAwareStatus = maxProjected < 99.5 ? .wavesInsufficient : .noSpeedData

        return WaveProjectionResult(
            currentSpeed: nil,
            projectedSdAtReset: maxProjected,
            wavesNeeded: wavesAvailable,
            currentWaveIndex: 1,
            waves: [],
            targetSpeed: 0,
            status: status,
            projectedFinishTime: nil
        )
    }

    // MARK: - Legacy API (fallback)

    func extractRecentIntervals(count: Int = 5) -> [ConsumptionInterval] {
        let dataPoints = UsageHistoryStore.shared.currentCycleDataPoints
        guard dataPoints.count >= 2 else { return [] }

        var intervals: [ConsumptionInterval] = []
        for i in 1..<dataPoints.count {
            let prev = dataPoints[i - 1]
            let curr = dataPoints[i]
            let change = curr.utilization - prev.utilization
            if change > 0 {
                let duration = curr.timestamp.timeIntervalSince(prev.timestamp)
                guard duration >= 60 else { continue }
                intervals.append(ConsumptionInterval(
                    fromUtilization: prev.utilization,
                    toUtilization: curr.utilization,
                    duration: duration,
                    timestamp: curr.timestamp
                ))
            }
        }
        return Array(intervals.sorted { $0.timestamp > $1.timestamp }.prefix(count))
    }

    func generatePredictions(
        remainingPercent: Double, remainingTime: TimeInterval
    ) -> [SprintPrediction] {
        extractRecentIntervals().map { interval in
            let predicted = interval.predictTimeToFinish(remainingPercent: remainingPercent)
            return SprintPrediction(
                interval: interval,
                predictedFinishTime: predicted,
                remainingTime: remainingTime,
                delta: remainingTime - predicted
            )
        }
    }

    func generateWeightedPrediction(
        remainingPercent: Double, remainingTime: TimeInterval
    ) -> WeightedPrediction? {
        let intervals = extractRecentIntervals()
        guard !intervals.isEmpty else { return nil }

        var weightedTpp: TimeInterval = 0
        var totalWeight: Double = 0
        for (i, interval) in intervals.enumerated() {
            let w = i < weights.count ? weights[i] : 0.05
            weightedTpp += interval.timePerPercent * w
            totalWeight += w
        }
        if totalWeight > 0 { weightedTpp /= totalWeight }

        let predicted = weightedTpp * remainingPercent
        return WeightedPrediction(
            predictedFinishTime: predicted,
            remainingTime: remainingTime,
            delta: remainingTime - predicted,
            confidence: min(Double(intervals.count) / 5.0, 1.0),
            sampleCount: intervals.count
        )
    }
}
