//
//  DevHelperPlugin.swift
//  DevHelperKit
//
//  开发助手插件 - 管理项目和运行脚本（SDK 版本）

import SwiftUI
import Combine
import ETermKit
import AppKit

// MARK: - 工作区数据存储（从事件获取）

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published var workspacePaths: [String] = []

    private init() {}

    func update(from payload: [String: Any]) {
        guard let workspaces = payload["workspaces"] as? [[String: Any]] else {
            return
        }
        workspacePaths = workspaces.compactMap { $0["path"] as? String }
    }
}

// MARK: - 开发助手插件

@objc(DevHelperPlugin)
@MainActor
public final class DevHelperPlugin: NSObject, ETermKit.Plugin {
    public static var id: String = "com.eterm.dev-helper"

    private weak var host: HostBridge?

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
    }

    public func deactivate() {
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        if eventName == "plugin.com.eterm.workspace.didUpdate" {
            WorkspaceStore.shared.update(from: payload)
        }
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "dev-helper-entry" else { return nil }
        return AnyView(DevHelperView(host: host))
    }
}

// MARK: - 选中的脚本

struct SelectedScript: Equatable {
    let project: DetectedProject
    let script: ProjectScript

    static func == (lhs: SelectedScript, rhs: SelectedScript) -> Bool {
        lhs.project.id == rhs.project.id && lhs.script.id == rhs.script.id
    }
}

// MARK: - 项目树节点

final class ProjectTreeNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let fullPath: String
    let project: DetectedProject?
    @Published var children: [ProjectTreeNode]
    @Published var isExpanded: Bool = true

    var isLeaf: Bool { project != nil }

    init(name: String, fullPath: String, project: DetectedProject? = nil, children: [ProjectTreeNode] = []) {
        self.name = name
        self.fullPath = fullPath
        self.project = project
        self.children = children
    }
}

// MARK: - 开发助手视图

struct DevHelperView: View {
    weak var host: HostBridge?

    var body: some View {
        DevHelperContentView(host: host)
    }
}

private struct DevHelperContentView: View {
    weak var host: HostBridge?

    @ObservedObject private var workspaceStore = WorkspaceStore.shared
    @ObservedObject private var taskManager = RunningTaskManager.shared

    @State private var projects: [DetectedProject] = []
    @State private var rootNodes: [ProjectTreeNode] = []
    @State private var selectedScript: SelectedScript?
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部安全区域（PageBar）
            Color.clear.frame(height: 52)

            HSplitView {
                // 左侧：项目列表
                ProjectListView(
                    rootNodes: rootNodes,
                    selectedScript: $selectedScript,
                    isScanning: isScanning,
                    onRefresh: scanProjects
                )
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

                // 右侧：终端
                TerminalPanelView(selectedScript: $selectedScript, host: host)
            }
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            scanProjects()
        }
        .onChange(of: workspaceStore.workspacePaths) {
            scanProjects()
        }
    }

    private func scanProjects() {
        isScanning = true

        let paths = workspaceStore.workspacePaths

        DispatchQueue.global(qos: .userInitiated).async {
            let folderURLs = paths.map { URL(fileURLWithPath: $0) }
            let scannedProjects = ProjectScanner.shared.scan(folders: folderURLs)

            DispatchQueue.main.async {
                projects = scannedProjects
                rootNodes = buildProjectTree(from: scannedProjects)
                isScanning = false
            }
        }
    }

    // MARK: - 构建前缀树

    private func buildProjectTree(from projects: [DetectedProject]) -> [ProjectTreeNode] {
        guard !projects.isEmpty else { return [] }

        let pathComponents = projects.map { project -> (components: [String], project: DetectedProject) in
            let components = (project.path.path as NSString).pathComponents.filter { $0 != "/" }
            return (components, project)
        }

        let allComponents = pathComponents.map { $0.components }
        let commonPrefix = findCommonPrefix(allComponents)

        return buildTree(
            items: pathComponents,
            prefixLength: commonPrefix.count,
            basePath: "/" + commonPrefix.joined(separator: "/")
        )
    }

    private func findCommonPrefix(_ paths: [[String]]) -> [String] {
        guard let first = paths.first, paths.count > 1 else { return [] }

        var prefix: [String] = []
        for (index, component) in first.enumerated() {
            if paths.allSatisfy({ index < $0.count && $0[index] == component }) {
                prefix.append(component)
            } else {
                break
            }
        }
        return prefix
    }

    private func buildTree(
        items: [(components: [String], project: DetectedProject)],
        prefixLength: Int,
        basePath: String
    ) -> [ProjectTreeNode] {
        var groups: [String: [(components: [String], project: DetectedProject)]] = [:]

        for item in items {
            guard prefixLength < item.components.count else { continue }
            let nextComponent = item.components[prefixLength]
            groups[nextComponent, default: []].append(item)
        }

        var nodes: [ProjectTreeNode] = []

        for (component, groupItems) in groups.sorted(by: { $0.key < $1.key }) {
            let nodePath = basePath.isEmpty ? "/\(component)" : "\(basePath)/\(component)"

            if groupItems.count == 1 && groupItems[0].components.count == prefixLength + 1 {
                let node = ProjectTreeNode(
                    name: component,
                    fullPath: nodePath,
                    project: groupItems[0].project
                )
                nodes.append(node)
            } else {
                let exactMatch = groupItems.first { $0.components.count == prefixLength + 1 }
                let children = buildTree(
                    items: groupItems.filter { $0.components.count > prefixLength + 1 },
                    prefixLength: prefixLength + 1,
                    basePath: nodePath
                )

                let node = ProjectTreeNode(
                    name: component,
                    fullPath: nodePath,
                    project: exactMatch?.project,
                    children: children
                )
                nodes.append(node)
            }
        }

        return nodes
    }
}

// MARK: - 项目列表视图

private struct ProjectListView: View {
    let rootNodes: [ProjectTreeNode]
    @Binding var selectedScript: SelectedScript?
    let isScanning: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "hammer.fill")
                    .foregroundColor(.orange)
                Text("项目")
                    .font(.headline)
                Spacer()

                if isScanning {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新项目列表")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if rootNodes.isEmpty {
                EmptyProjectsView(isScanning: isScanning)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let commonPath = findCommonBasePath() {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text(commonPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            Divider().padding(.horizontal, 12)
                        }

                        ForEach(rootNodes) { node in
                            ProjectTreeNodeView(
                                node: node,
                                level: 0,
                                selectedScript: $selectedScript
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func findCommonBasePath() -> String? {
        guard let first = rootNodes.first else { return nil }
        let fullPath = first.fullPath
        let name = first.name

        if fullPath.hasSuffix(name) {
            let basePath = String(fullPath.dropLast(name.count))
            if !basePath.isEmpty && basePath != "/" {
                return basePath
            }
        }
        return nil
    }
}

// MARK: - 项目树节点视图

private struct ProjectTreeNodeView: View {
    @ObservedObject var node: ProjectTreeNode
    let level: Int
    @Binding var selectedScript: SelectedScript?

    @State private var isHovered = false
    @State private var isScriptsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !node.children.isEmpty {
                    Button(action: { node.isExpanded.toggle() }) {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if node.isLeaf, let project = node.project, !project.scripts.isEmpty {
                    Button(action: { isScriptsExpanded.toggle() }) {
                        Image(systemName: isScriptsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 16)
                }

                Image(systemName: nodeIcon)
                    .foregroundColor(nodeColor)
                    .font(.system(size: 14))

                Text(node.name)
                    .font(.system(size: 13, weight: node.isLeaf ? .medium : .regular))
                    .foregroundColor(node.isLeaf ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                if let project = node.project, !project.scripts.isEmpty {
                    Text("\(project.scripts.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, CGFloat(level) * 16 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { isHovered = $0 }

            if node.isLeaf, isScriptsExpanded, let project = node.project {
                ForEach(project.scripts) { script in
                    ScriptRowView(
                        script: script,
                        project: project,
                        level: level + 1,
                        selectedScript: $selectedScript
                    )
                }
            }

            if node.isExpanded {
                ForEach(node.children) { child in
                    ProjectTreeNodeView(
                        node: child,
                        level: level + 1,
                        selectedScript: $selectedScript
                    )
                }
            }
        }
    }

    private var nodeIcon: String {
        if let project = node.project {
            switch project.type {
            case "node": return "shippingbox.fill"
            case "rust": return "gearshape.fill"
            case "go": return "hare.fill"
            default: return "folder.fill"
            }
        }
        return "folder"
    }

    private var nodeColor: Color {
        if let project = node.project {
            switch project.type {
            case "node": return .green
            case "rust": return .orange
            case "go": return .cyan
            default: return .secondary
            }
        }
        return .secondary
    }
}

// MARK: - 脚本行视图

private struct ScriptRowView: View {
    let script: ProjectScript
    let project: DetectedProject
    let level: Int
    @Binding var selectedScript: SelectedScript?

    @ObservedObject private var taskManager = RunningTaskManager.shared
    @State private var isHovered = false

    private var isRunning: Bool {
        taskManager.isRunning(project: project, script: script)
    }

    private var isSelected: Bool {
        selectedScript?.project.id == project.id && selectedScript?.script.id == script.id
    }

    var body: some View {
        HStack(spacing: 8) {
            // 运行状态指示器
            Circle()
                .fill(isRunning ? Color.green : Color.clear)
                .frame(width: 6, height: 6)

            Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundColor(isHovered ? .green : .secondary)

            Text(script.displayName ?? script.name)
                .font(.system(size: 12))
                .foregroundColor(isHovered || isSelected ? .primary : .secondary)

            Spacer()
        }
        .padding(.leading, CGFloat(level) * 16 + 20)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            selectedScript = SelectedScript(project: project, script: script)
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        return isHovered ? Color.primary.opacity(0.05) : Color.clear
    }
}

// MARK: - 空状态视图

private struct EmptyProjectsView: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: isScanning ? "magnifyingglass" : "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text(isScanning ? "正在扫描..." : "暂无项目")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("请先在「工作区」中添加文件夹")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 终端面板视图

private struct TerminalPanelView: View {
    @Binding var selectedScript: SelectedScript?
    weak var host: HostBridge?

    @ObservedObject private var taskManager = RunningTaskManager.shared

    @State private var currentTerminalId: Int = -1

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                if let selected = selectedScript {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.secondary)
                    Text("\(selected.project.name) - \(selected.script.name)")
                        .font(.headline)

                    if taskManager.isRunning(project: selected.project, script: selected.script) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                    }
                } else {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                    Text("选择一个脚本")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()

                if currentTerminalId >= 0 {
                    Text("Terminal #\(currentTerminalId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // 终端区域
            if let selected = selectedScript {
                TerminalInstanceView(
                    selectedScript: selected,
                    currentTerminalId: $currentTerminalId,
                    host: host
                )
            } else {
                // 空状态
                VStack {
                    Spacer()
                    Image(systemName: "arrow.left")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("从左侧选择一个脚本运行")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 终端实例视图

private struct TerminalInstanceView: View {
    let selectedScript: SelectedScript
    @Binding var currentTerminalId: Int
    weak var host: HostBridge?

    @ObservedObject private var taskManager = RunningTaskManager.shared
    @State private var terminalKey = UUID()
    @State private var isStarting = false  // 正在启动中

    private var isRunning: Bool {
        taskManager.isRunning(project: selectedScript.project, script: selectedScript.script)
    }

    private var shouldShowTerminal: Bool {
        isRunning || isStarting
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowTerminal {
                // 显示终端（使用 TerminalPlaceholder）
                TerminalPlaceholder(
                    terminalId: currentTerminalId,
                    cwd: selectedScript.project.path.path
                )
                .id(terminalKey)
                .onAppear {
                    if currentTerminalId < 0, let hostRef = host {
                        // 创建嵌入终端
                        let newId = hostRef.createEmbeddedTerminal(cwd: selectedScript.project.path.path)
                        if newId >= 0 {
                            currentTerminalId = newId
                            // 注意：这个路径不会执行命令，命令通过 startScript 执行
                        }
                    }
                }
            } else {
                // 未运行：显示启动按钮
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green.opacity(0.8))

                    Text("点击启动")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text(selectedScript.script.command)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)

                    Button("启动") {
                        startScript()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Spacer()
                }
            }
        }
        .onChange(of: selectedScript) { _, newValue in
            // 切换脚本时重置状态
            isStarting = false
            if let existingId = taskManager.getTerminalId(project: newValue.project, script: newValue.script) {
                currentTerminalId = existingId
            } else {
                currentTerminalId = -1
            }
            terminalKey = UUID()
        }
    }

    private func startScript() {
        // 捕获需要的变量避免 weak 引用失效
        guard let hostRef = host else { return }
        let projectPath = selectedScript.project.path.path
        let scriptCommand = selectedScript.script.command
        let project = selectedScript.project
        let script = selectedScript.script

        // 创建终端
        let newId = hostRef.createEmbeddedTerminal(cwd: projectPath)
        guard newId >= 0 else { return }

        currentTerminalId = newId
        isStarting = true
        terminalKey = UUID()

        // 延迟执行命令（捕获所有需要的值）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [taskManager] in
            // 注册任务
            taskManager.registerTask(
                project: project,
                script: script,
                terminalId: newId
            )

            // 执行命令
            let command = "cd '\(projectPath)' && \(scriptCommand)\n"
            hostRef.writeToTerminal(terminalId: newId, data: command)
        }
    }
}
