//
//  claude-helper
//
//  Created by claude-helper on 2025/11/23.
//

import Foundation

/// 单次用量变化的时间间隔
struct ConsumptionInterval: Identifiable {
    let id = UUID()
    let fromUtilization: Double      // 起始用量 %
    let toUtilization: Double        // 结束用量 %
    let duration: TimeInterval       // 花费时间（秒）
    let timestamp: Date              // 变化发生时间

    /// 计算：按此速率用完剩余额度需要多久
    func predictTimeToFinish(remainingPercent: Double) -> TimeInterval {
        guard timePerPercent > 0, remainingPercent > 0 else { return 0 }
        return timePerPercent * remainingPercent
    }

    /// 每 1% 需要多少时间（秒）
    var timePerPercent: TimeInterval {
        let percentChange = toUtilization - fromUtilization
        guard percentChange > 0 else { return 0 }
        return duration / percentChange
    }

    /// 变化的百分比幅度
    var percentChange: Double {
        toUtilization - fromUtilization
    }
}

/// 冲刺预测状态
enum SprintStatus {
    case surplus    // 富余（差值 > 2小时）
    case balanced   // 平衡（差值在 +-2小时内）
    case deficit    // 超出（差值 < -2小时）

    /// 状态颜色标识
    var emoji: String {
        switch self {
        case .surplus: return "🟢"
        case .balanced: return "🟡"
        case .deficit: return "🔴"
        }
    }
}

/// 单个预测结果
struct SprintPrediction: Identifiable {
    let id = UUID()
    let interval: ConsumptionInterval
    let predictedFinishTime: TimeInterval  // 按此速率用完需要的时间
    let remainingTime: TimeInterval        // 剩余时间（到周期重置）
    let delta: TimeInterval                // 差值（正=富余，负=超出）

    /// 根据差值计算状态
    var status: SprintStatus {
        let twoHours: TimeInterval = 2 * 3600
        if delta > twoHours {
            return .surplus
        } else if delta < -twoHours {
            return .deficit
        } else {
            return .balanced
        }
    }
}

/// 加权平均预测结果
struct WeightedPrediction {
    let predictedFinishTime: TimeInterval  // 加权预测用完时间
    let remainingTime: TimeInterval        // 剩余时间
    let delta: TimeInterval                // 差值
    let confidence: Double                 // 置信度 0-1（基于数据点数量）
    let sampleCount: Int                   // 样本数量

    var status: SprintStatus {
        let twoHours: TimeInterval = 2 * 3600
        if delta > twoHours {
            return .surplus
        } else if delta < -twoHours {
            return .deficit
        } else {
            return .balanced
        }
    }
}

/// 冲刺预测器
/// 从历史用量数据中提取最近的用量变化间隔，并生成预测
final class SprintPredictor {
    static let shared = SprintPredictor()

    /// 权重配置：最近的权重最高
    private let weights: [Double] = [0.40, 0.25, 0.20, 0.10, 0.05]

    private init() {}

    /// 从历史数据中提取最近 N 次用量变化的间隔
    /// - Parameter count: 需要提取的间隔数量，默认为 5
    /// - Returns: 用量变化间隔数组，按时间倒序排列（最近的在前）
    func extractRecentIntervals(count: Int = 5) -> [ConsumptionInterval] {
        let dataPoints = UsageHistoryStore.shared.currentCycleDataPoints

        // 需要至少 2 个数据点才能计算间隔
        guard dataPoints.count >= 2 else { return [] }

        var intervals: [ConsumptionInterval] = []

        // 遍历相邻数据点，找出 utilization 发生变化的点
        for i in 1..<dataPoints.count {
            let prevPoint = dataPoints[i - 1]
            let currPoint = dataPoints[i]

            // 计算用量变化
            let utilizationChange = currPoint.utilization - prevPoint.utilization

            // 只关注用量增加的情况（正常消耗）
            if utilizationChange > 0 {
                let duration = currPoint.timestamp.timeIntervalSince(prevPoint.timestamp)

                guard duration >= 60 else { continue }

                let interval = ConsumptionInterval(
                    fromUtilization: prevPoint.utilization,
                    toUtilization: currPoint.utilization,
                    duration: duration,
                    timestamp: currPoint.timestamp
                )
                intervals.append(interval)
            }
        }

        // 按时间倒序排列（最近的在前），取最近 N 条
        let sortedIntervals = intervals.sorted { $0.timestamp > $1.timestamp }
        return Array(sortedIntervals.prefix(count))
    }

    /// 生成冲刺预测
    /// - Parameters:
    ///   - remainingPercent: 剩余额度百分比（如 26 表示剩余 26%）
    ///   - remainingTime: 剩余时间（秒），到周期重置
    /// - Returns: 预测结果数组
    func generatePredictions(
        remainingPercent: Double,
        remainingTime: TimeInterval
    ) -> [SprintPrediction] {
        let intervals = extractRecentIntervals()

        return intervals.map { interval in
            let predictedFinish = interval.predictTimeToFinish(remainingPercent: remainingPercent)
            let delta = remainingTime - predictedFinish

            return SprintPrediction(
                interval: interval,
                predictedFinishTime: predictedFinish,
                remainingTime: remainingTime,
                delta: delta
            )
        }
    }

    /// 生成加权平均预测
    /// - Parameters:
    ///   - remainingPercent: 剩余额度百分比
    ///   - remainingTime: 剩余时间（秒）
    /// - Returns: 加权平均预测结果，如果数据不足返回 nil
    func generateWeightedPrediction(
        remainingPercent: Double,
        remainingTime: TimeInterval
    ) -> WeightedPrediction? {
        let intervals = extractRecentIntervals()

        guard !intervals.isEmpty else { return nil }

        // 计算加权平均的 timePerPercent
        var weightedTimePerPercent: TimeInterval = 0
        var totalWeight: Double = 0

        for (index, interval) in intervals.enumerated() {
            let weight = index < weights.count ? weights[index] : 0.05
            weightedTimePerPercent += interval.timePerPercent * weight
            totalWeight += weight
        }

        // 归一化权重（如果数据点不足5个）
        if totalWeight > 0 {
            weightedTimePerPercent /= totalWeight
        }

        // 计算预测用完时间
        let predictedFinishTime = weightedTimePerPercent * remainingPercent
        let delta = remainingTime - predictedFinishTime

        // 置信度基于样本数量（5个样本=100%置信度）
        let confidence = min(Double(intervals.count) / 5.0, 1.0)

        return WeightedPrediction(
            predictedFinishTime: predictedFinishTime,
            remainingTime: remainingTime,
            delta: delta,
            confidence: confidence,
            sampleCount: intervals.count
        )
    }
}
