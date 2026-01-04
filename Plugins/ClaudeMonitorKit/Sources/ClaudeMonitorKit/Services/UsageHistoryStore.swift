//
//  UsageHistoryStore.swift
//  ClaudeMonitorKit
//
//  用量历史存储 - 支持持久化到 JSON 文件

import Foundation
import Combine
import ETermKit

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
    private let filePath: String

    /// 周期重置阈值：当利用率下降超过此百分比时，认为发生了重置
    private let resetThreshold: Double = 50.0

    /// 数据保留天数
    private let retentionDays: Int = 30

    private init() {
        filePath = ClaudeMonitorPaths.usageHistory

        // 从旧位置迁移数据
        migrateFromOldLocation()

        loadData()
        cleanOldData()

        // 初始化当前周期ID
        currentCycleId = dataPoints.last?.cycleId ?? generateCycleId()
    }

    // MARK: - Public Methods

    /// 记录新的用量数据点
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

    private func generateCycleId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func loadData() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            dataPoints = []
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            dataPoints = try decoder.decode([UsageDataPoint].self, from: data)
        } catch {
            logError("[ClaudeMonitor] 加载用量历史数据失败: \(error)")
            dataPoints = []
        }
    }

    private func saveData() {
        do {
            try ClaudeMonitorPaths.ensureParentDirectory(for: filePath)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(dataPoints)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            logError("[ClaudeMonitor] 保存用量历史数据失败: \(error)")
        }
    }

    private func migrateFromOldLocation() {
        // 从旧的 Application Support 目录迁移
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let oldFileURL = appSupport
            .appendingPathComponent("claude-helper")
            .appendingPathComponent("usage_history.json")

        guard FileManager.default.fileExists(atPath: oldFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: oldFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let oldData = try decoder.decode([UsageDataPoint].self, from: data)

            try ClaudeMonitorPaths.ensureParentDirectory(for: filePath)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let newData = try encoder.encode(oldData)
            try newData.write(to: URL(fileURLWithPath: filePath), options: .atomic)

            try FileManager.default.removeItem(at: oldFileURL)
        } catch {
            logError("[ClaudeMonitor] 迁移用量历史数据失败: \(error)")
        }
    }

    private func cleanOldData() {
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: Date()
        ) ?? Date()

        let originalCount = dataPoints.count
        dataPoints = dataPoints.filter { $0.timestamp >= cutoffDate }

        if originalCount - dataPoints.count > 0 {
            saveData()
        }
    }
}
