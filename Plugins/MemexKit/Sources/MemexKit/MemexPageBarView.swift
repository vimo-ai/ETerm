//
//  MemexPageBarView.swift
//  MemexKit
//
//  PageBar 数据概览 - 常驻显示数据库统计信息
//

import SwiftUI
import Foundation

// MARK: - Stats Store

@MainActor
final class MemexStatsStore: ObservableObject {
    static let shared = MemexStatsStore()

    @Published var stats: MemexStats?
    @Published var embeddingStats: EmbeddingStats?

    private var timer: Timer?

    private init() {}

    func startPolling() {
        // 首次立即加载
        Task { await refresh() }

        // 每 60s 刷新
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() async {
        // memex-rs 未运行时不显示统计
        guard MemexService.shared.isRunning else {
            stats = nil
            embeddingStats = nil
            return
        }

        // 基础统计（FFI 或 HTTP）
        stats = try? await MemexService.shared.getStats()

        // Embedding 统计（仅 HTTP）
        let url = MemexService.shared.baseURL.appendingPathComponent("api/embedding/stats")
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200 {
            embeddingStats = try? JSONDecoder().decode(EmbeddingStats.self, from: data)
        } else {
            embeddingStats = nil
        }
    }
}

// MARK: - PageBar View

public struct MemexPageBarView: View {
    @ObservedObject private var store = MemexStatsStore.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            if let stats = store.stats {
                statGroup(icon: "folder.fill", value: formatNumber(stats.projectCount), label: "项目")
                divider
                statGroup(icon: "bubble.left.and.bubble.right.fill", value: formatNumber(stats.sessionCount), label: "会话")
                divider
                statGroup(icon: "text.bubble.fill", value: formatNumber(stats.messageCount), label: "消息")

                // Embedding 统计
                if let emb = store.embeddingStats {
                    divider
                    statGroup(icon: "cube.transparent", value: formatNumber(emb.indexed), label: "已索引")
                    if emb.pending > 0 {
                        statGroup(icon: "clock.fill", value: formatNumber(emb.pending), label: "待索引")
                    }
                }
            } else {
                // memex 未启动
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text("memex 未启动")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .fixedSize()
    }

    // MARK: - Components

    private func statGroup(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: 12)
    }

    // MARK: - Formatting

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }
}
