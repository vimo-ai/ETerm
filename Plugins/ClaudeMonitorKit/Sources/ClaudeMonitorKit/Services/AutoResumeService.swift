//
//  AutoResumeService.swift
//  ClaudeMonitorKit
//
//  周限重置自动拉起服务
//  当周限打满时，根据 resetsAt 或手动设定的时间点，到时自动创建终端并启动 Claude。

import Foundation
import Combine
import ETermKit

final class AutoResumeService: ObservableObject {
    static let shared = AutoResumeService()

    /// 当前调度的拉起时间（nil 表示未调度）
    @Published private(set) var scheduledDate: Date?

    /// 调度来源
    @Published private(set) var scheduleSource: ScheduleSource = .none

    enum ScheduleSource: Equatable {
        case none       // 未调度
        case auto       // 来自 API resetsAt
        case manual     // 用户手动设定
    }

    // MARK: - 持久化 keys

    private static let scheduledDateKey = "AutoResumeScheduledDate"
    private static let scheduleSourceKey = "AutoResumeScheduleSource"

    private weak var host: (any HostBridge)?
    private var cancellable: AnyCancellable?
    private var timer: Timer?

    /// 防止重复执行：记录上次执行的 resetsAt 时间
    private var lastPerformedResetDate: Date?

    private init() {
        restoreSchedule()
    }

    deinit {
        timer?.invalidate()
        cancellable?.cancel()
    }

    func configure(host: any HostBridge) {
        self.host = host
        observe()

        // 启动时检查是否有已过时间的持久化调度
        if let date = scheduledDate, date.timeIntervalSinceNow <= 0 {
            performResume()
        }
    }

    /// 停止观察（插件 deactivate 时调用）
    func stop() {
        cancellable?.cancel()
        cancellable = nil
        timer?.invalidate()
        timer = nil
        host = nil
    }

    // MARK: - Public

    /// 手动设定拉起时间
    @MainActor
    func scheduleManual(at date: Date) {
        scheduleResume(at: date, source: .manual)
    }

    /// 取消当前调度
    @MainActor
    func cancel() {
        cancelSchedule()
    }

    // MARK: - Private

    private func observe() {
        cancellable = WeeklyUsageTracker.shared.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
    }

    private func handleSnapshot(_ snapshot: WeeklyUsageSnapshot) {
        guard UserDefaults.standard.bool(forKey: "AutoResumeEnabled") else {
            if scheduleSource == .auto {
                cancelSchedule()
            }
            return
        }

        // 手动调度优先，不被自动覆盖
        if scheduleSource == .manual { return }

        guard snapshot.recommendation == .pause else {
            if scheduleSource == .auto {
                cancelSchedule()
            }
            return
        }

        let resetDate = snapshot.overall.endDate

        // 已经为这个时间点执行过，不再重复
        if let last = lastPerformedResetDate,
           abs(last.timeIntervalSince(resetDate)) < 60 {
            return
        }

        // 同一时间点不重复调度（1 分钟容差）
        if let scheduled = scheduledDate,
           abs(scheduled.timeIntervalSince(resetDate)) < 60 {
            return
        }

        scheduleResume(at: resetDate, source: .auto)
    }

    private func scheduleResume(at date: Date, source: ScheduleSource) {
        cancelSchedule()

        let delay = date.timeIntervalSinceNow
        guard delay > 0 else {
            // 已过时间且是自动调度，检查是否已执行过
            if source == .auto {
                if let last = lastPerformedResetDate,
                   abs(last.timeIntervalSince(date)) < 60 {
                    return
                }
            }
            performResume()
            return
        }

        scheduledDate = date
        scheduleSource = source
        persistSchedule()

        // 使用 Timer(fireAt:) 基于挂钟时间，睡眠唤醒后立即触发
        let fireTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.performResume()
        }
        RunLoop.main.add(fireTimer, forMode: .common)
        timer = fireTimer
    }

    private func cancelSchedule() {
        timer?.invalidate()
        timer = nil
        scheduledDate = nil
        scheduleSource = .none
        clearPersistedSchedule()
    }

    private func performResume() {
        let resumeDate = scheduledDate

        // 清理调度状态
        timer?.invalidate()
        timer = nil
        scheduledDate = nil
        scheduleSource = .none
        clearPersistedSchedule()

        // 记录已执行时间，防重复
        if let date = resumeDate {
            lastPerformedResetDate = date
        }

        guard let host = host else { return }

        guard let terminalId = host.createTerminalTab(cwd: nil) else {
            return
        }

        // 等终端初始化完成后发送命令
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.sendInput(terminalId: terminalId, text: "claude", pressEnter: true)
        }
    }

    // MARK: - 持久化

    private func persistSchedule() {
        guard let date = scheduledDate else { return }
        UserDefaults.standard.set(date, forKey: Self.scheduledDateKey)
        UserDefaults.standard.set(scheduleSource == .manual ? "manual" : "auto",
                                  forKey: Self.scheduleSourceKey)
    }

    private func clearPersistedSchedule() {
        UserDefaults.standard.removeObject(forKey: Self.scheduledDateKey)
        UserDefaults.standard.removeObject(forKey: Self.scheduleSourceKey)
    }

    private func restoreSchedule() {
        guard let date = UserDefaults.standard.object(forKey: Self.scheduledDateKey) as? Date else {
            return
        }
        let sourceStr = UserDefaults.standard.string(forKey: Self.scheduleSourceKey) ?? "auto"
        let source: ScheduleSource = sourceStr == "manual" ? .manual : .auto

        scheduledDate = date
        scheduleSource = source

        // 实际的 Timer 调度在 configure(host:) 中完成
    }
}
