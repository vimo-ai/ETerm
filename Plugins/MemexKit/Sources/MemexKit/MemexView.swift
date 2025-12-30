//
//  MemexView.swift
//  MemexKit
//
//  Memex 主视图 - 支持原生状态仪表盘和 Web UI 两种模式
//

import SwiftUI
import ETermKit

// MARK: - View Mode

enum MemexViewMode: String, CaseIterable {
    case status = "状态"
    case webUI = "Web UI"

    var icon: String {
        switch self {
        case .status: return "gauge.with.dots.needle.bottom.50percent"
        case .webUI: return "globe"
        }
    }
}

// MARK: - MemexView

/// Memex 主视图
/// 布局：顶部安全区 + Header + 内容区域（各自独立，互不干扰）
struct MemexView: View {
    @StateObject private var viewModel = MemexViewModel()
    @State private var viewMode: MemexViewMode = .webUI

    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部安全区域（Tab 栏）- 纯 SwiftUI
            Color.clear
                .frame(height: 52)

            // 2. Header 区域 - 纯 SwiftUI，包含模式切换
            MemexHeaderView(
                isRunning: viewModel.isServiceRunning,
                viewMode: $viewMode,
                onRefresh: { Task { await viewModel.refresh() } }
            )

            Divider()

            // 3. 内容区域 - 根据模式显示不同内容
            //    WebView 只在这个区域内渲染，不会覆盖上面的控件
            Group {
                switch viewMode {
                case .status:
                    StatusContentView(viewModel: viewModel)
                case .webUI:
                    WebUIContentView(
                        isServiceRunning: viewModel.isServiceRunning,
                        port: viewModel.port,
                        onStartService: { Task { await viewModel.startService() } }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.refresh()
        }
    }
}

// MARK: - Status Content View

private struct StatusContentView: View {
    @ObservedObject var viewModel: MemexViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 服务状态卡片
                ServiceStatusCard(
                    isRunning: viewModel.isServiceRunning,
                    port: viewModel.port,
                    onStart: { Task { await viewModel.startService() } },
                    onStop: { Task { await viewModel.stopService() } }
                )

                // 统计信息卡片
                if let stats = viewModel.stats {
                    StatsCard(stats: stats)
                }

                // MCP 信息卡片
                if viewModel.isServiceRunning {
                    MCPInfoCard(port: viewModel.port)
                }

                // 错误提示
                if let error = viewModel.errorMessage {
                    ErrorCard(message: error)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Web UI Content View

private struct WebUIContentView: View {
    let isServiceRunning: Bool
    let port: UInt16
    let onStartService: () -> Void

    var body: some View {
        if isServiceRunning {
            // 服务运行中，显示 Web UI
            MemexWebContainer(port: port)
        } else {
            // 服务未运行，显示启动提示
            VStack(spacing: 20) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("Memex 服务未运行")
                    .font(.headline)

                Text("启动服务后即可使用 Web UI")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    print("[MemexKit] 🔘 启动按钮被点击")
                    onStartService()
                } label: {
                    Label("启动服务", systemImage: "play.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MemexViewModel: ObservableObject {
    @Published var isServiceRunning = false
    @Published var stats: MemexStats?
    @Published var errorMessage: String?

    var port: UInt16 { MemexService.shared.port }

    func refresh() async {
        isServiceRunning = await MemexService.shared.checkHealth()

        if isServiceRunning {
            do {
                stats = try await MemexService.shared.getStats()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            stats = nil
        }
    }

    func startService() async {
        print("[MemexKit] 🚀 startService() 被调用")
        do {
            try MemexService.shared.start()
            print("[MemexKit] ✅ MemexService.start() 成功")
            // 等待服务启动
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refresh()
        } catch {
            print("[MemexKit] ❌ MemexService.start() 失败: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func stopService() async {
        MemexService.shared.stop()
        await refresh()
    }
}

// MARK: - Header

private struct MemexHeaderView: View {
    let isRunning: Bool
    @Binding var viewMode: MemexViewMode
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            // 左侧：图标和标题
            Image(systemName: "brain.head.profile")
                .foregroundColor(.purple)
            Text("Memex")
                .font(.headline)

            // 状态指示器
            Circle()
                .fill(isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Spacer()

            // 中间：模式切换（使用自定义按钮替代 segmented Picker）
            HStack(spacing: 0) {
                ForEach(MemexViewMode.allCases, id: \.self) { mode in
                    Button {
                        viewMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(viewMode == mode ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                }
            }
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
            .frame(width: 160)

            Spacer()

            // 右侧：刷新按钮
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新状态")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Service Status Card

private struct ServiceStatusCard: View {
    let isRunning: Bool
    let port: UInt16
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: isRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isRunning ? .green : .red)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isRunning ? "服务运行中" : "服务未运行")
                        .font(.headline)

                    if isRunning {
                        Text("http://localhost:\(port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: isRunning ? onStop : onStart) {
                    Text(isRunning ? "停止" : "启动")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isRunning ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                        .foregroundColor(isRunning ? .red : .green)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Stats Card

private struct StatsCard: View {
    let stats: MemexStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据概览")
                .font(.headline)

            HStack(spacing: 16) {
                StatItem(
                    icon: "folder.fill",
                    value: "\(stats.projectCount)",
                    label: "项目",
                    color: .blue
                )

                StatItem(
                    icon: "bubble.left.and.bubble.right.fill",
                    value: "\(stats.sessionCount)",
                    label: "会话",
                    color: .purple
                )

                StatItem(
                    icon: "text.bubble.fill",
                    value: formatNumber(stats.messageCount),
                    label: "消息",
                    color: .orange
                )
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }
}

private struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - MCP Info Card

private struct MCPInfoCard: View {
    let port: UInt16

    @State private var copied = false

    var mcpEndpoint: String {
        "http://localhost:\(port)/api/mcp"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.cyan)
                Text("MCP 服务")
                    .font(.headline)
            }

            HStack {
                Text(mcpEndpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Button(action: copyEndpoint) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("复制 MCP 端点")
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            Text("可在 Claude Desktop 配置中添加此 HTTP MCP 服务")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpEndpoint, forType: .string)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Error Card

private struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    MemexView()
        .frame(width: 400, height: 600)
}
