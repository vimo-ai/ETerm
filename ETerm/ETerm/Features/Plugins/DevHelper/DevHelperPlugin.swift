//
//  DevHelperPlugin.swift
//  ETerm
//
//  开发助手插件 - 管理项目和运行脚本（从 node-helper 演变）

import SwiftUI
import SwiftData
import Combine

/// 开发助手插件
final class DevHelperPlugin: Plugin {
    static let id = "dev-helper"
    static let name = "开发助手"
    static let version = "1.0.0"

    func activate(context: PluginContext) {

        context.ui.registerPluginPageEntry(
            for: Self.id,
            pluginName: Self.name,
            icon: "hammer.fill"
        ) {
            AnyView(DevHelperView())
        }

    }

    func deactivate() {
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
    var body: some View {
        DevHelperContentView()
            .modelContainer(WorkspaceDataStore.shared)
    }
}

private struct DevHelperContentView: View {
    @Query(sort: \WorkspaceFolder.addedAt) private var folders: [WorkspaceFolder]
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
                TerminalPanelView(selectedScript: $selectedScript)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            scanProjects()
        }
        .onChange(of: folders) {
            scanProjects()
        }
    }

    private func scanProjects() {
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let folderURLs = folders.map { URL(fileURLWithPath: $0.path) }
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
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else if node.isLeaf, let project = node.project, !project.scripts.isEmpty {
                    Button(action: { isScriptsExpanded.toggle() }) {
                        Image(systemName: isScriptsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
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
                    currentTerminalId: $currentTerminalId
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
    }
}

// MARK: - 终端实例视图

private struct TerminalInstanceView: View {
    let selectedScript: SelectedScript
    @Binding var currentTerminalId: Int

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
                // 显示终端
                EmbeddedTerminalView(
                    initialCommand: nil,
                    workingDirectory: selectedScript.project.path.path,
                    onTerminalCreated: { id in
                        currentTerminalId = id
                        // 终端创建完成后执行命令
                        if isStarting {
                            executeStartCommand(terminalId: id)
                        }
                    }
                )
                .id(terminalKey)
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
            }
            terminalKey = UUID()
        }
    }

    private func startScript() {
        // 标记为启动中，显示终端
        isStarting = true
        terminalKey = UUID()
    }

    private func executeStartCommand(terminalId: Int) {
        // 注册任务
        taskManager.registerTask(
            project: selectedScript.project,
            script: selectedScript.script,
            terminalId: terminalId
        )

        // 重置启动状态
        isStarting = false

        // 延迟一点执行命令，确保终端完全就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let command = "cd '\(selectedScript.project.path.path)' && \(selectedScript.script.command)"
            NotificationCenter.default.post(
                name: .embeddedTerminalWriteInput,
                object: nil,
                userInfo: [
                    "terminalId": terminalId,
                    "data": command + "\n"
                ]
            )
        }
    }
}
