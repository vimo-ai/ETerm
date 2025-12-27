//
//  HistoryPanelView.swift
//  HistoryKit
//
//  历史快照侧边栏视图

import SwiftUI
import AppKit

// MARK: - HistoryPanelView

/// 历史快照面板视图
public struct HistoryPanelView: View {

    @ObservedObject private var viewModel: HistoryPanelViewModel
    @ObservedObject private var state: HistoryState

    public init(service: HistoryService, state: HistoryState) {
        self._viewModel = ObservedObject(wrappedValue: HistoryPanelViewModel(service: service))
        self._state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        let _ = print("[HistoryPanelView] body called, state.workspaces.count = \(state.workspaces.count), state id = \(ObjectIdentifier(state))")
        VStack(spacing: 0) {
            // 顶部安全区域
            Color.clear
                .frame(height: 52)

            // 标题栏
            HistoryHeaderView(
                onRefresh: { Task { await viewModel.refresh(for: state.currentWorkspace) } },
                onAutoSelect: { state.autoSelectWorkspace() }
            )

            // 工作区选择器
            if !state.workspaces.isEmpty {
                WorkspaceSelectorView(
                    workspaces: state.workspaces,
                    currentSelection: state.currentWorkspace,
                    onSelect: { state.selectWorkspace($0) }
                )
            }

            Divider()

            // 主内容区
            if state.currentWorkspace.isEmpty {
                NoWorkspaceView()
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.snapshots.isEmpty {
                HistoryEmptyView(workspace: state.currentWorkspace)
            } else {
                HistoryListView(
                    snapshots: viewModel.snapshots,
                    onRestore: { id in Task { await viewModel.restore(cwd: state.currentWorkspace, snapshotId: id) } },
                    onDelete: { id in Task { await viewModel.delete(cwd: state.currentWorkspace, snapshotId: id) } }
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // 自动选择工作区
            if state.currentWorkspace.isEmpty {
                state.autoSelectWorkspace()
            }
        }
        .onChange(of: state.currentWorkspace) { _, newValue in
            if !newValue.isEmpty {
                Task { await viewModel.refresh(for: newValue) }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class HistoryPanelViewModel: ObservableObject {

    @Published var snapshots: [Snapshot] = []
    @Published var isLoading = false

    private let service: HistoryService

    init(service: HistoryService) {
        self.service = service
    }

    func refresh(for workspace: String) async {
        guard !workspace.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let result = await service.list(cwd: workspace, limit: 50)

        if let snapshotsData = result["snapshots"] as? [[String: Any]] {
            snapshots = snapshotsData.compactMap { parseSnapshot($0) }
        }
    }

    func restore(cwd: String, snapshotId: String) async {
        guard !cwd.isEmpty else { return }

        do {
            try await service.restore(cwd: cwd, snapshotId: snapshotId)
            await refresh(for: cwd)
        } catch {
            print("[HistoryKit] 恢复失败: \(error)")
        }
    }

    func delete(cwd: String, snapshotId: String) async {
        guard !cwd.isEmpty else { return }

        do {
            try await service.deleteSnapshot(cwd: cwd, snapshotId: snapshotId)
            await refresh(for: cwd)
        } catch {
            print("[HistoryKit] 删除失败: \(error)")
        }
    }

    private func parseSnapshot(_ dict: [String: Any]) -> Snapshot? {
        guard let id = dict["id"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval,
              let fileCount = dict["fileCount"] as? Int,
              let changedCount = dict["changedCount"] as? Int,
              let storedSize = dict["storedSize"] as? Int64 else {
            return nil
        }

        return Snapshot(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            label: dict["label"] as? String,
            source: dict["source"] as? String,
            fileCount: fileCount,
            changedCount: changedCount,
            storedSize: storedSize
        )
    }
}

// MARK: - Header View

private struct HistoryHeaderView: View {
    let onRefresh: () -> Void
    let onAutoSelect: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(.blue)
            Text("历史快照")
                .font(.headline)
            Spacer()

            Button(action: onAutoSelect) {
                Image(systemName: "location")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("定位到当前目录")

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Workspace Selector

private struct WorkspaceSelectorView: View {
    let workspaces: [String]
    let currentSelection: String
    let onSelect: (String) -> Void

    // 使用 @State 本地变量避免 Binding(get:set:) 的问题
    @State private var localSelection: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .font(.caption)

            Picker("", selection: $localSelection) {
                ForEach(workspaces, id: \.self) { path in
                    Text(displayName(for: path))
                        .tag(path)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .onAppear {
            localSelection = currentSelection
        }
        .onChange(of: currentSelection) { _, newValue in
            // 外部状态变化时同步到本地
            if localSelection != newValue {
                localSelection = newValue
            }
        }
        .onChange(of: localSelection) { _, newValue in
            // 本地选择变化时通知外部
            if newValue != currentSelection && !newValue.isEmpty {
                onSelect(newValue)
            }
        }
    }

    private func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - No Workspace View

private struct NoWorkspaceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("未选择工作区")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("请先在工作区面板添加项目目录")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty View

private struct HistoryEmptyView: View {
    let workspace: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无快照")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("快照会在工作区活动时自动创建")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List View

private struct HistoryListView: View {
    let snapshots: [Snapshot]
    let onRestore: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snapshots) { snapshot in
                    SnapshotRowView(
                        snapshot: snapshot,
                        onRestore: { onRestore(snapshot.id) },
                        onDelete: { onDelete(snapshot.id) }
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Row View

private struct SnapshotRowView: View {
    let snapshot: Snapshot
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var timeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.timestamp, relativeTo: Date())
    }

    private var labelColor: Color {
        switch snapshot.label {
        case "scheduled":
            return .gray
        case "claude-session-start":
            return .orange
        case "claude-pre-edit":
            return .purple
        case "manual":
            return .blue
        case "pre-restore-backup":
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(timeString)
                        .font(.system(size: 13, weight: .medium))

                    if let label = snapshot.label {
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(labelColor.opacity(0.2))
                            .foregroundColor(labelColor)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 8) {
                    Label("\(snapshot.fileCount)", systemImage: "doc")
                    Label("\(snapshot.changedCount)", systemImage: "pencil")
                    Label(formatSize(snapshot.storedSize), systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onRestore) {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("恢复到此快照")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除快照")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Preview

#Preview {
    HistoryEmptyView(workspace: "/Users/test/project")
        .frame(width: 300, height: 400)
}
