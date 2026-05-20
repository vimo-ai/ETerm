//
//  MemexInfoPanelView.swift
//  MemexKit
//
//  信息面板中的 Memex 仪表盘（与 Claude Monitor 并列）
//

import SwiftUI
import ETermKit
import SQLite3

// MARK: - Info Panel View

struct MemexInfoPanelView: View {
    @StateObject private var viewModel = MemexInfoPanelViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            serviceStatusRow
            if viewModel.isServiceRunning {
                statsRow
                embeddingSection
                compactStatusSection
                knowledgeSection
                if viewModel.syncEnabled {
                    syncPeersSection
                }
            }
        }
        .task {
            await viewModel.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Service Status

    private var serviceStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isServiceRunning ? ThemeColors.UI.success : ThemeColors.UI.error)
                .frame(width: 6, height: 6)

            Text("Memex")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textPrimary)

            if viewModel.isServiceRunning {
                Text(":\(viewModel.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
            }

            Spacer()

            Button {
                Task {
                    if viewModel.isServiceRunning {
                        await viewModel.stopService()
                    } else {
                        await viewModel.startService()
                    }
                }
            } label: {
                Text(viewModel.isServiceRunning ? "STOP" : "START")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.isServiceRunning ? ThemeColors.UI.error : ThemeColors.UI.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(viewModel.isServiceRunning ? ThemeColors.UI.error.opacity(0.5) : ThemeColors.UI.success.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 16) {
            statItem(value: viewModel.projectCount, label: "PROJ")
            statItem(value: viewModel.sessionCount, label: "SESS")
            statItem(value: viewModel.messageCount, label: "MSG")

            if let dbSize = viewModel.dbSizeBytes {
                Spacer()
                Text(formatBytes(dbSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
            }
        }
    }

    private func statItem(value: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text(formatNumber(value))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textMuted)
        }
    }

    // MARK: - Embedding

    private var embeddingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 1.0))
                Text("EMBEDDING")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .tracking(1)

                Spacer()

                if let stats = viewModel.embeddingStats {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(stats.embeddingAvailable ? ThemeColors.UI.success : ThemeColors.UI.error)
                            .frame(width: 4, height: 4)
                        Text(stats.embeddingModel)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(ThemeColors.UI.textMuted)
                    }
                }
            }

            if let stats = viewModel.embeddingStats {
                HStack(spacing: 16) {
                    embeddingStat(value: stats.indexed, label: "INDEXED", color: ThemeColors.UI.success)
                    embeddingStat(value: stats.pending, label: "PENDING", color: Color.orange)
                    if stats.failed > 0 {
                        embeddingStat(value: stats.failed, label: "FAILED", color: ThemeColors.UI.error)

                        Button {
                            Task { await viewModel.resetFailedEmbeddings() }
                        } label: {
                            Text("RESET")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(ThemeColors.UI.error)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(ThemeColors.UI.error.opacity(0.5), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isResettingFailed)
                    }
                }

                if stats.isRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 8, height: 8)
                        Text("indexing \(formatNumber(stats.pending)) remaining...")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(ThemeColors.UI.textMuted)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ThemeColors.UI.bgTertiary)
        )
    }

    private func embeddingStat(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(formatNumber(value))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textMuted)
        }
    }

    // MARK: - Compact Status

    private var compactStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.UI.accent)
                Text("COMPACT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .tracking(1)

                Spacer()

                statusPill(label: "ENGINE", active: viewModel.compactEnabled)
                statusPill(label: "QUEUE", active: viewModel.compactQueueAvailable)
                statusPill(label: "DB", active: viewModel.compactDbConnected)
            }

            if viewModel.compactEnabled {
                HStack(spacing: 16) {
                    compactStat(value: viewModel.compactTalkSummaries, label: "TALKS")
                    compactStat(value: viewModel.compactSessionSummaries, label: "SESS")
                    compactStat(value: viewModel.compactTrackedSessions, label: "TRACKED")
                    if viewModel.compactProcessing > 0 {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 8, height: 8)
                            Text("\(viewModel.compactProcessing)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.orange)
                        }
                    }
                }

                if let lastUpdated = viewModel.compactLastUpdated {
                    Text("last: \(lastUpdated)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textMuted)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ThemeColors.UI.bgTertiary)
        )
    }

    private func compactStat(value: Int64, label: String) -> some View {
        HStack(spacing: 4) {
            Text(formatNumber64(value))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textPrimary)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textMuted)
        }
    }

    private func statusPill(label: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? ThemeColors.UI.success : ThemeColors.UI.error)
                .frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(active ? ThemeColors.UI.textSecondary : ThemeColors.UI.textMuted)
        }
    }

    // MARK: - Knowledge (L4)

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.9, green: 0.6, blue: 0.2))
                Text("KNOWLEDGE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .tracking(1)

                Spacer()

                if viewModel.knowledgeEnabled {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ThemeColors.UI.success)
                            .frame(width: 4, height: 4)
                        if let model = viewModel.knowledgeChatModel {
                            Text(model)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(ThemeColors.UI.textMuted)
                        }
                    }
                } else {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ThemeColors.UI.textMuted)
                            .frame(width: 4, height: 4)
                        Text("DISABLED")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(ThemeColors.UI.textMuted)
                    }
                }
            }

            if viewModel.knowledgeEnabled {
                // Global stats
                HStack(spacing: 16) {
                    compactStat(value: viewModel.knowledgeNodes, label: "NODES")
                    compactStat(value: viewModel.knowledgeClusters, label: "CLUSTERS")
                }

                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundColor(ThemeColors.UI.textMuted)
                    TextField("搜索项目...", text: $viewModel.knowledgeSearch)
                        .font(.system(size: 10, design: .monospaced))
                        .textFieldStyle(.plain)
                        .onSubmit {
                            Task { await viewModel.loadKnowledgeStatus() }
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ThemeColors.UI.bgSecondary)
                )

                // Pending projects
                if viewModel.pendingProjects.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(ThemeColors.UI.success)
                        Text("all up to date")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(ThemeColors.UI.textMuted)
                    }
                } else {
                    ForEach(viewModel.pendingProjects) { project in
                        knowledgeProjectRow(project)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ThemeColors.UI.bgTertiary)
        )
    }

    private func knowledgeProjectRow(_ project: PendingKnowledgeProject) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textPrimary)
                        .lineLimit(1)
                    Text("\(project.pendingSessions) sessions pending")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                }

                Spacer()

                if project.isExtracting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 20)
                } else {
                    Button {
                        Task { await viewModel.extractKnowledge(projectId: project.id) }
                    } label: {
                        Text("EXTRACT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.9, green: 0.6, blue: 0.2))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(red: 0.9, green: 0.6, blue: 0.2).opacity(0.6), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Job progress bar
            if let job = viewModel.knowledgeJob, job.projectId == project.id, job.status == "running" {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(job.processed + job.failed), total: Double(max(job.totalSessions, 1)))
                        .tint(Color(red: 0.9, green: 0.6, blue: 0.2))
                    HStack(spacing: 6) {
                        Text("\(job.processed + job.failed)/\(job.totalSessions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(ThemeColors.UI.textSecondary)
                        if job.nodesExtracted > 0 {
                            Text("· \(job.nodesExtracted) nodes")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(ThemeColors.UI.textSecondary)
                        }
                        if job.failed > 0 {
                            Text("· \(job.failed) failed")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red.opacity(0.9))
                        }
                        Spacer()
                        Button {
                            Task { await viewModel.cancelKnowledgeExtraction() }
                        } label: {
                            Text("CANCEL")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.red.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(.red.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Job cancelled
            if let job = viewModel.knowledgeJob, job.projectId == project.id, job.status == "cancelled" {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("cancelled at \(job.processed)/\(job.totalSessions), \(job.nodesExtracted) nodes saved")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                }
            }

            // Job done summary
            if let job = viewModel.knowledgeJob, job.projectId == project.id, job.status == "done" {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.UI.success)
                    Text("\(job.processed) done, \(job.nodesExtracted) nodes extracted")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textSecondary)
                }
            }

            // Job error
            if let job = viewModel.knowledgeJob, job.projectId == project.id, job.status == "error" {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("extraction error")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red.opacity(0.9))
                }
            }
        }
    }

    // MARK: - Sync Peers

    private var syncPeersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.UI.accent)
                Text("SYNC PEERS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .tracking(1)
            }

            if viewModel.isLoadingPeers {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("loading...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.textMuted)
                }
            } else if !viewModel.peers.isEmpty {
                ForEach(viewModel.peers) { peer in
                    peerRow(peer)
                }
                if let error = viewModel.peersError {
                    Text(error)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(ThemeColors.UI.warning)
                        .lineLimit(2)
                }
            } else if let error = viewModel.peersError {
                Text(error)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.error)
                    .lineLimit(2)
            } else {
                Text("no peers connected")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ThemeColors.UI.bgTertiary)
        )
    }

    private func peerRow(_ peer: SyncPeer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Circle()
                    .fill(peer.isRecentlyActive ? ThemeColors.UI.success : ThemeColors.UI.textMuted)
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 6)

                Text(peer.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textPrimary)

                Spacer()

                Text(formatNumber(peer.sessions))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.accent)
                Text("sess")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .padding(.leading, 2)
                    .padding(.trailing, 10)

                Text(formatNumber(peer.messages))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textPrimary)
                Text("msg")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ThemeColors.UI.textMuted)
                    .padding(.leading, 2)
                    .padding(.trailing, 10)

                Text(peer.lastActiveText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(peer.isRecentlyActive ? ThemeColors.UI.success : ThemeColors.UI.textMuted)
            }

            if !peer.activeProjects.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8))
                        .foregroundColor(peer.isRecentlyActive ? ThemeColors.UI.accent : ThemeColors.UI.textMuted)
                    Text(peer.activeProjects.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(peer.isRecentlyActive ? ThemeColors.UI.textSecondary : ThemeColors.UI.textMuted)
                        .lineLimit(1)
                }
                .padding(.leading, 11)
            }
        }
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

    private func formatNumber64(_ n: Int64) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }

    private func formatTimestamp(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "\(bytes) B"
    }
}

// MARK: - Knowledge Data Model

struct PendingKnowledgeProject: Identifiable {
    let id: Int64
    let name: String
    let path: String
    let pendingSessions: Int64
    var isExtracting: Bool = false
}

struct KnowledgeJobInfo {
    let projectId: Int64
    let totalSessions: Int
    let processed: Int
    let failed: Int
    let nodesExtracted: Int
    let status: String
    let startedAt: String
}

// MARK: - Data Model

struct SyncPeer: Identifiable {
    let id: String
    let name: String
    let sessions: Int
    let messages: Int
    let todaySessions: Int
    let lastActiveAt: Date?
    let activeProject: String?
    let activeProjects: [String]

    var isRecentlyActive: Bool {
        guard let lastActive = lastActiveAt else { return false }
        return Date().timeIntervalSince(lastActive) < 600
    }

    var lastActiveText: String {
        guard let lastActive = lastActiveAt else { return "never" }
        let interval = Date().timeIntervalSince(lastActive)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - ViewModel

@MainActor
final class MemexInfoPanelViewModel: ObservableObject {
    @Published var isServiceRunning = false
    @Published var projectCount = 0
    @Published var sessionCount = 0
    @Published var messageCount = 0
    @Published var dbSizeBytes: UInt64?
    @Published var embeddingStats: EmbeddingStats?
    @Published var compactEnabled = false
    @Published var compactQueueAvailable = false
    @Published var compactDbConnected = false
    @Published var compactTalkSummaries: Int64 = 0
    @Published var compactSessionSummaries: Int64 = 0
    @Published var compactTrackedSessions: Int64 = 0
    @Published var compactProcessing: Int64 = 0
    @Published var compactLastUpdated: String?
    @Published var knowledgeEnabled = false
    @Published var knowledgeChatModel: String?
    @Published var knowledgeNodes: Int64 = 0
    @Published var knowledgeClusters: Int64 = 0
    @Published var knowledgeSearch = ""
    @Published var pendingProjects: [PendingKnowledgeProject] = []
    @Published var knowledgeJob: KnowledgeJobInfo?
    private var jobPollTask: Task<Void, Never>?
    @Published var isResettingFailed = false
    @Published var syncEnabled = false
    @Published var peers: [SyncPeer] = []
    @Published var isLoadingPeers = false
    @Published var peersError: String?

    var port: UInt16 { MemexService.shared.port }

    func refresh() async {
        isServiceRunning = await MemexService.shared.checkHealth()

        if isServiceRunning {
            if let stats = try? await MemexService.shared.getStats() {
                projectCount = stats.projectCount
                sessionCount = stats.sessionCount
                messageCount = stats.messageCount
                dbSizeBytes = stats.dbSizeBytes
            }

            await loadEmbeddingStats()
            await loadCompactStatus()
            await loadKnowledgeStatus()
            await loadSyncConfig()

            if syncEnabled {
                await loadPeers()
            }
        }
    }

    func startService() async {
        try? MemexService.shared.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
    }

    func stopService() async {
        await MemexService.shared.stopAsync()
        await refresh()
    }

    func resetFailedEmbeddings() async {
        isResettingFailed = true
        defer { isResettingFailed = false }

        let url = MemexService.shared.baseURL.appendingPathComponent("api/embedding/reset-failed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        await loadEmbeddingStats()
    }

    private func loadEmbeddingStats() async {
        let url = MemexService.shared.baseURL.appendingPathComponent("api/embedding/stats")
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            embeddingStats = nil
            return
        }
        embeddingStats = try? JSONDecoder().decode(EmbeddingStats.self, from: data)
    }

    private func loadCompactStatus() async {
        let url = MemexService.shared.baseURL.appendingPathComponent("api/compact/status")
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            compactEnabled = false
            compactQueueAvailable = false
            compactDbConnected = false
            return
        }
        compactEnabled = json["enabled"] as? Bool ?? false
        compactQueueAvailable = json["queueAvailable"] as? Bool ?? false
        compactDbConnected = json["dbConnected"] as? Bool ?? false
        compactTalkSummaries = (json["talkSummaries"] as? NSNumber)?.int64Value ?? 0
        compactSessionSummaries = (json["sessionSummaries"] as? NSNumber)?.int64Value ?? 0
        compactTrackedSessions = (json["trackedSessions"] as? NSNumber)?.int64Value ?? 0
        compactProcessing = (json["processing"] as? NSNumber)?.int64Value ?? 0
        if let ts = json["lastUpdated"] as? String, !ts.isEmpty {
            compactLastUpdated = Self.formatCompactTimestamp(ts)
        } else {
            compactLastUpdated = nil
        }
    }

    func loadKnowledgeStatus() async {
        var urlComponents = URLComponents(url: MemexService.shared.baseURL.appendingPathComponent("api/knowledge/status"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "limit", value: "5")]
        let searchTerm = knowledgeSearch.trimmingCharacters(in: .whitespaces)
        if !searchTerm.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: searchTerm))
        }
        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            knowledgeEnabled = false
            return
        }

        knowledgeEnabled = json["enabled"] as? Bool ?? false
        knowledgeChatModel = json["chatModel"] as? String
        knowledgeNodes = (json["nodes"] as? NSNumber)?.int64Value ?? 0
        knowledgeClusters = (json["clusters"] as? NSNumber)?.int64Value ?? 0

        if let pendingArr = json["pending"] as? [[String: Any]] {
            pendingProjects = pendingArr.compactMap { item in
                guard let id = (item["id"] as? NSNumber)?.int64Value,
                      let name = item["name"] as? String else { return nil }
                return PendingKnowledgeProject(
                    id: id,
                    name: name,
                    path: item["path"] as? String ?? "",
                    pendingSessions: (item["pending_sessions"] as? NSNumber)?.int64Value ?? 0
                )
            }
        } else {
            pendingProjects = []
        }

        // Parse job progress
        if let jobJson = json["job"] as? [String: Any],
           let status = jobJson["status"] as? String {
            knowledgeJob = KnowledgeJobInfo(
                projectId: (jobJson["project_id"] as? NSNumber)?.int64Value ?? 0,
                totalSessions: (jobJson["total_sessions"] as? NSNumber)?.intValue ?? 0,
                processed: (jobJson["processed"] as? NSNumber)?.intValue ?? 0,
                failed: (jobJson["failed"] as? NSNumber)?.intValue ?? 0,
                nodesExtracted: (jobJson["nodes_extracted"] as? NSNumber)?.intValue ?? 0,
                status: status,
                startedAt: jobJson["started_at"] as? String ?? ""
            )
            // If running, mark corresponding project as extracting
            if status == "running" {
                let pid = (jobJson["project_id"] as? NSNumber)?.int64Value ?? 0
                if let idx = pendingProjects.firstIndex(where: { $0.id == pid }) {
                    pendingProjects[idx].isExtracting = true
                }
            }
        } else {
            knowledgeJob = nil
        }
    }

    func extractKnowledge(projectId: Int64) async {
        if let idx = pendingProjects.firstIndex(where: { $0.id == projectId }) {
            pendingProjects[idx].isExtracting = true
        }

        let url = MemexService.shared.baseURL.appendingPathComponent("api/knowledge/extract")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "projectId": projectId,
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            if let idx = pendingProjects.firstIndex(where: { $0.id == projectId }) {
                pendingProjects[idx].isExtracting = false
            }
            return
        }

        if status == "started" || status == "already_running" {
            startJobPolling()
        } else {
            if let idx = pendingProjects.firstIndex(where: { $0.id == projectId }) {
                pendingProjects[idx].isExtracting = false
            }
        }
    }

    func cancelKnowledgeExtraction() async {
        let url = MemexService.shared.baseURL.appendingPathComponent("api/knowledge/cancel")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func startJobPolling() {
        jobPollTask?.cancel()
        jobPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await loadKnowledgeStatus()
                if let job = knowledgeJob, job.status != "running" {
                    // Job finished — clear extracting state, stop polling
                    for i in pendingProjects.indices {
                        pendingProjects[i].isExtracting = false
                    }
                    // Keep job info visible for a moment, then clear
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    knowledgeJob = nil
                    await loadKnowledgeStatus()
                    break
                }
            }
        }
    }

    private func loadSyncConfig() async {
        let configPath = NSHomeDirectory() + "/.vimo/memex/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sync = json["sync"] as? [String: Any],
              let enabled = sync["enabled"] as? Bool else {
            syncEnabled = false
            return
        }
        syncEnabled = enabled && (sync["server"] as? String)?.isEmpty == false
    }

    private func loadPeers() async {
        isLoadingPeers = true
        peersError = nil
        defer { isLoadingPeers = false }

        let configPath = NSHomeDirectory() + "/.vimo/memex/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sync = json["sync"] as? [String: Any],
              let server = sync["server"] as? String,
              !server.isEmpty else {
            peersError = "config read failed"
            return
        }

        var apiKey = sync["api_key"] as? String ?? ""
        if apiKey.isEmpty {
            apiKey = Self.readApiKeyFromSyncDb() ?? ""
        }
        let caPath = (sync["ca_cert"] as? String)
            .map { ($0 as NSString).expandingTildeInPath }
        let urlString = "\(server)/api/sync/peers"

        // URLSession first, curl fallback
        let responseData: Data
        do {
            responseData = try await fetchViaURLSession(urlString: urlString, apiKey: apiKey)
        } catch {
            let urlSessionError = error.localizedDescription
            do {
                responseData = try await fetchViaCurl(urlString: urlString, apiKey: apiKey, caPath: caPath)
                peersError = "⚠ URLSession: \(urlSessionError) (curl fallback)"
            } catch {
                peersError = "URLSession: \(urlSessionError) | curl: \(error.localizedDescription)"
                return
            }
        }

        do {
            if let peersJson = try JSONSerialization.jsonObject(with: responseData) as? [[String: Any]] {
                peers = peersJson.compactMap { parsePeer($0) }
                if peers.isEmpty {
                    peersError = "parsed 0 from \(peersJson.count) items"
                }
            } else {
                peersError = "JSON parse failed"
            }
        } catch {
            peersError = "JSON: \(error.localizedDescription)"
        }
    }

    private func fetchViaURLSession(urlString: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let delegate = SelfSignedTrustDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "peers", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        return data
    }

    private func fetchViaCurl(urlString: String, apiKey: String, caPath: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                var args = ["-s", "--max-time", "8"]
                if let caPath = caPath {
                    args += ["--cacert", caPath]
                }
                if !apiKey.isEmpty {
                    args += ["-H", "Authorization: Bearer \(apiKey)"]
                }
                args.append(urlString)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if process.terminationStatus == 0 && !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "curl", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "curl exit \(process.terminationStatus)"]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func formatCompactTimestamp(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }

    private static func readApiKeyFromSyncDb() -> String? {
        let dbPath = NSHomeDirectory() + "/.vimo/db/sync.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM sync_state WHERE key = 'api_key' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private func parsePeer(_ json: [String: Any]) -> SyncPeer? {
        guard let name = json["name"] as? String else { return nil }
        return SyncPeer(
            id: name,
            name: name,
            sessions: (json["sessions"] as? NSNumber)?.intValue ?? 0,
            messages: (json["messages"] as? NSNumber)?.intValue ?? 0,
            todaySessions: (json["today_sessions"] as? NSNumber)?.intValue ?? 0,
            lastActiveAt: (json["last_active_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            activeProject: json["active_project"] as? String,
            activeProjects: (json["active_projects"] as? [String]) ?? (json["active_project"] as? String).map { [$0] } ?? []
        )
    }
}

// MARK: - Self-Signed TLS Trust

private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
