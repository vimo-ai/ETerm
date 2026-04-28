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
        HStack(spacing: 0) {
            Circle()
                .fill(peer.isRecentlyActive ? ThemeColors.UI.success : ThemeColors.UI.textMuted)
                .frame(width: 5, height: 5)
                .padding(.trailing, 6)

            Text(peer.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ThemeColors.UI.textPrimary)
                .frame(minWidth: 60, alignment: .leading)

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

// MARK: - Data Model

struct SyncPeer: Identifiable {
    let id: String
    let name: String
    let sessions: Int
    let messages: Int
    let todaySessions: Int
    let lastActiveAt: Date?

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
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request, delegate: delegate)
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
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
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
            lastActiveAt: (json["last_active_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        )
    }
}

// MARK: - Self-Signed TLS Trust

private final class SelfSignedTrustDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
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
