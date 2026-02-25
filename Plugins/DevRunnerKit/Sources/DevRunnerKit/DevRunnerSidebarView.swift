//
//  DevRunnerSidebarView.swift
//  DevRunnerKit
//
//  DevRunner sidebar tab 视图 — 项目列表 + 进程状态

import SwiftUI
import AppKit

// MARK: - Main Sidebar View

struct DevRunnerSidebarView: View {

    @ObservedObject var bridge: DevRunnerBridge
    let plugin: DevRunnerPlugin

    @State private var isDetecting = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部安全区占位
            Color.clear.frame(height: 52)

            // 标题栏
            headerBar

            Divider().background(Color.white.opacity(0.1))

            if bridge.projectStates.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .foregroundColor(.cyan)
            Text("DevRunner")
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            // 添加项目
            Button(action: addProject) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("添加项目")
            // 刷新
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 32))
                .foregroundColor(.gray.opacity(0.5))
            Text("暂无项目")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("点击 + 添加项目目录")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project List

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(bridge.projectStates.indices, id: \.self) { index in
                    ProjectRow(
                        state: $bridge.projectStates[index],
                        bridge: bridge,
                        plugin: plugin
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择项目目录"
        panel.prompt = "添加"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                isDetecting = true
                defer { isDetecting = false }

                do {
                    let projects = try bridge.detectProjects(at: url.path)
                    if projects.isEmpty {
                        print("[DevRunner] 未在 \(url.path) 检测到项目")
                        return
                    }
                    // 打开检测到的所有项目
                    for project in projects {
                        do {
                            try bridge.openProject(project.path)
                        } catch {
                            print("[DevRunner] 打开项目失败 \(project.name): \(error)")
                        }
                    }
                    // 加载每个新打开项目的 targets
                    loadTargetsForAll()
                } catch {
                    print("[DevRunner] 检测项目失败: \(error)")
                }
            }
        }
    }

    private func refresh() {
        bridge.refreshProcesses()
        bridge.refreshOpened()
        loadTargetsForAll()
        updateProjectProcesses()
    }

    private func loadTargetsForAll() {
        for i in bridge.projectStates.indices {
            if bridge.projectStates[i].targets.isEmpty {
                do {
                    let targets = try bridge.listTargets(for: bridge.projectStates[i].project.path)
                    bridge.projectStates[i].targets = targets
                    if bridge.projectStates[i].selectedTarget == nil, let first = targets.first {
                        bridge.projectStates[i].selectedTarget = first.name
                    }
                } catch {
                    print("[DevRunner] 加载 targets 失败: \(error)")
                }
            }
        }
    }

    private func updateProjectProcesses() {
        for i in bridge.projectStates.indices {
            let path = bridge.projectStates[i].project.path
            bridge.projectStates[i].process = bridge.processes.first(where: {
                $0.projectPath == path && $0.isRunning
            })
        }
    }
}

// MARK: - Project Row

struct ProjectRow: View {

    @Binding var state: ProjectState
    @ObservedObject var bridge: DevRunnerBridge
    let plugin: DevRunnerPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 项目标题行
            HStack(spacing: 8) {
                // 状态指示灯
                statusDot

                // 项目名 + adapter 标签
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.project.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(state.project.adapterType)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(adapterColor.opacity(0.15))
                        .foregroundColor(adapterColor)
                        .cornerRadius(3)
                }

                Spacer()

                // 操作按钮
                actionButtons
            }

            // Target 选择（有多个 target 时显示）
            if state.targets.count > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: targetBinding) {
                        ForEach(state.targets) { target in
                            Text(target.name).tag(target.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                .padding(.leading, 20)
            }

            // 运行中 metrics
            if let process = state.process, process.isRunning {
                metricsRow(process: process)
            }

            // 失败信息
            if let process = state.process, process.status == "failed",
               let msg = process.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .contextMenu {
            Button("关闭项目") {
                // 强制 kill daemon session 再关闭项目
                if let tid = state.terminalId {
                    plugin.forceCloseTerminal(terminalId: tid)
                }
                try? bridge.closeProject(state.project.path)
            }
        }
    }

    // MARK: - Status Dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        guard let process = state.process else { return .gray.opacity(0.4) }
        switch process.status {
        case "running": return .green
        case "stopped": return .gray
        case "failed":  return .red
        default:        return .gray.opacity(0.4)
        }
    }

    // MARK: - Adapter Color

    private var adapterColor: Color {
        switch state.project.adapterType {
        case "xcode": return .blue
        case "node":  return .green
        default:      return .orange
        }
    }

    // MARK: - Target Binding

    private var targetBinding: Binding<String> {
        Binding(
            get: { state.selectedTarget ?? state.targets.first?.name ?? "" },
            set: { state.selectedTarget = $0 }
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            // 终端已关闭，显示重开按钮
            if state.terminalId == nil, state.process != nil {
                Button(action: reopenTerminal) {
                    Image(systemName: "terminal.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("重新打开终端")
            }

            if let process = state.process, process.isRunning {
                // Stop
                Button(action: stopProcess) {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("停止")

                // Restart
                Button(action: restartProcess) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("重启")
            } else {
                // Run
                Button(action: runProcess) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("运行")
            }
        }
    }

    // MARK: - Metrics Row

    private func metricsRow(process: ProcessInfo) -> some View {
        HStack(spacing: 8) {
            if let pid = process.pid {
                metricLabel("PID", value: "\(pid)")
            }
            if let metrics = state.metrics {
                metricLabel("CPU", value: String(format: "%.0f%%", metrics.cpuPercent))
                metricLabel("MEM", value: metrics.formattedMemory)
            }
            // 运行时长
            let elapsed = Int(Date().timeIntervalSince1970) - Int(process.startedAt)
            metricLabel("TIME", value: formatDuration(elapsed))
        }
        .padding(.leading, 20)
    }

    private func metricLabel(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\(seconds % 3600 / 60)m"
    }

    // MARK: - Actions

    private func reopenTerminal() {
        plugin.reopenTerminal(state: &state)
    }

    private func runProcess() {
        do {
            try plugin.runAndOpenTerminal(state: &state)
        } catch {
            print("[DevRunner] 运行失败: \(error)")
        }
    }

    private func stopProcess() {
        guard let process = state.process else { return }

        // 主路径：通过终端发送 Ctrl+C
        if let terminalId = state.terminalId {
            plugin.sendCtrlC(terminalId: terminalId)
            print("[DevRunner] 发送 Ctrl+C 到终端 \(terminalId)")

            // 1s 后检查进程是否停止，仍在运行则 SIGTERM
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                bridge.refreshProcesses()
                let updated = bridge.processes.first(where: { $0.processId == process.processId })
                if updated?.isRunning == true {
                    print("[DevRunner] Ctrl+C 未生效，发送 SIGTERM")
                    try? bridge.stopProcess(process.processId)
                }
                state.process = bridge.processes.first(where: {
                    $0.projectPath == state.project.path
                })
            }
        } else {
            // 无终端 ID，直接 SIGTERM
            do {
                try bridge.stopProcess(process.processId)
                print("[DevRunner] 停止进程 \(process.processId)")
            } catch {
                print("[DevRunner] 停止失败: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                bridge.refreshProcesses()
                state.process = bridge.processes.first(where: {
                    $0.projectPath == state.project.path
                })
            }
        }
    }

    private func restartProcess() {
        stopProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            runProcess()
        }
    }
}
