//
//  UsageHistoryStore.swift
//  claude-helper
//
//  Created by 💻higuaifan on 2025/11/23.
//

import Foundation
import Combine

/// 单个用量数据点
struct UsageDataPoint: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let utilization: Double           // 7天窗口百分比 0-100
    let fiveHourUtilization: Double?  // 5小时窗口百分比 0-100
    let opusUtilization: Double?      // Opus百分比 0-100
    let cycleId: String               // 周期标识，用于区分不同重置周期

    init(
        timestamp: Date,
        utilization: Double,
        fiveHourUtilization: Double? = nil,
        opusUtilization: Double? = nil,
        cycleId: String
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.utilization = utilization
        self.fiveHourUtilization = fiveHourUtilization
        self.opusUtilization = opusUtilization
        self.cycleId = cycleId
    }
}

/// 用量历史持久化存储
final class UsageHistoryStore: ObservableObject {
    static let shared = UsageHistoryStore()

    /// 所有历史数据点
    @Published private(set) var dataPoints: [UsageDataPoint] = []

    /// 当前周期的数据点
    var currentCycleDataPoints: [UsageDataPoint] {
        guard let lastCycleId = dataPoints.last?.cycleId else { return [] }
        return dataPoints.filter { $0.cycleId == lastCycleId }
    }

    /// 当前周期ID
    private(set) var currentCycleId: String = ""

    /// 存储文件路径
    private let fileURL: URL

    /// 周期重置阈值：当利用率下降超过此百分比时，认为发生了重置
    private let resetThreshold: Double = 50.0

    /// 数据保留天数
    private let retentionDays: Int = 30

    private init() {
        // 获取 Application Support 目录
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let appFolder = appSupport.appendingPathComponent("claude-helper")

        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: appFolder,
            withIntermediateDirectories: true
        )

        fileURL = appFolder.appendingPathComponent("usage_history.json")
        loadData()
        cleanOldData()

        // 初始化当前周期ID
        currentCycleId = dataPoints.last?.cycleId ?? generateCycleId()
    }

    // MARK: - Public Methods

    /// 记录新的用量数据点
    /// - Parameters:
    ///   - utilization: 7天窗口利用率 (0-100)
    ///   - fiveHourUtilization: 5小时窗口利用率 (0-100)，可选
    ///   - opusUtilization: Opus利用率 (0-100)，可选
    /// - Returns: 如果记录成功返回 true，如果值未变化则返回 false
    @discardableResult
    func record(
        utilization: Double,
        fiveHourUtilization: Double? = nil,
        opusUtilization: Double? = nil
    ) -> Bool {
        let now = Date()

        // 检测周期重置
        if let lastPoint = dataPoints.last {
            let utilizationDrop = lastPoint.utilization - utilization

            // 当利用率下降超过阈值时，生成新的周期ID
            if utilizationDrop > resetThreshold {
                currentCycleId = generateCycleId()
            }

            // 只在 utilization 变化时才记录新数据点
            // 使用0.1%的容差避免浮点数精度问题
            if abs(lastPoint.utilization - utilization) < 0.1 {
                return false
            }
        }

        let dataPoint = UsageDataPoint(
            timestamp: now,
            utilization: utilization,
            fiveHourUtilization: fiveHourUtilization,
            opusUtilization: opusUtilization,
            cycleId: currentCycleId
        )

        dataPoints.append(dataPoint)
        saveData()

        return true
    }

    /// 获取指定周期的数据点
    func dataPoints(forCycleId cycleId: String) -> [UsageDataPoint] {
        return dataPoints.filter { $0.cycleId == cycleId }
    }

    /// 获取所有周期ID列表（按时间排序）
    var allCycleIds: [String] {
        var seen = Set<String>()
        return dataPoints.compactMap { point -> String? in
            if seen.contains(point.cycleId) {
                return nil
            }
            seen.insert(point.cycleId)
            return point.cycleId
        }
    }

    // MARK: - Private Methods

    /// 生成新的周期ID
    private func generateCycleId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// 从磁盘加载数据
    private func loadData() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            dataPoints = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            dataPoints = try decoder.decode([UsageDataPoint].self, from: data)
        } catch {
            dataPoints = []
        }
    }

    /// 保存数据到磁盘
    private func saveData() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(dataPoints)
            try data.write(to: fileURL, options: .atomic)
        } catch {
        }
    }

    /// 清理超过保留期限的旧数据
    private func cleanOldData() {
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: Date()
        ) ?? Date()

        let originalCount = dataPoints.count
        dataPoints = dataPoints.filter { $0.timestamp >= cutoffDate }

        let removedCount = originalCount - dataPoints.count
        if removedCount > 0 {
            saveData()
        }
    }
}
