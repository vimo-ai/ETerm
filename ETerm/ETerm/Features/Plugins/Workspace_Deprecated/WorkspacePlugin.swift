//
//  WorkspacePlugin.swift
//  ETerm
//
//  工作区插件 - 管理项目工作区

import Combine
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ETermKit

/// 工作区插件
final class WorkspacePlugin: Plugin {
    static let id = "workspace"
    static let name = "工作区"
    static let version = "1.0.0"

    func activate(context: PluginContext) {
        // 预注册视图 Provider（用于 Session 恢复）
        context.ui.registerViewProvider(
            for: Self.id,
            viewId: Self.id,
            title: Self.name
        ) {
            AnyView(WorkspaceView())
        }

        // 注册侧边栏入口
        context.ui.registerSidebarTab(
            for: Self.id,
            pluginName: Self.name,
            tab: SidebarTab(
                id: "\(Self.id)-entry",
                title: Self.name,
                icon: "folder.badge.gearshape",
                viewProvider: { AnyView(EmptyView()) },
                onSelect: {
                    // 点击时创建或切换到 View Tab
                    context.ui.createViewTab(
                        for: Self.id,
                        viewId: Self.id,
                        title: Self.name,
                        placement: .split(.horizontal)
                    ) {
                        AnyView(WorkspaceView())
                    }
                }
            )
        )
    }

    func deactivate() {
    }
}

// MARK: - SwiftData Model

/// 工作区文件夹 - SwiftData 持久化模型
@Model
final class WorkspaceFolder {
    @Attribute(.unique) var path: String
    var addedAt: Date

    init(path: String) {
        self.path = path
        self.addedAt = Date()
    }
}

// MARK: - 路径树节点

/// 路径树节点 - 用于前缀收敛展示
final class PathTreeNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let fullPath: String
    let isLeaf: Bool
    @Published var children: [PathTreeNode]
    @Published var isExpanded: Bool = true

    init(name: String, fullPath: String, isLeaf: Bool = false, children: [PathTreeNode] = []) {
        self.name = name
        self.fullPath = fullPath
        self.isLeaf = isLeaf
        self.children = children
    }
}

// MARK: - ModelContainer 单例

/// Workspace 专用的 ModelContainer
enum WorkspaceDataStore {
    static let shared: ModelContainer = {
        let schema = Schema([WorkspaceFolder.self])

        do {
            // 尝试使用自定义路径
            let workspaceDBURL = URL(fileURLWithPath: ETermPaths.workspaceDatabase)
            let config = ModelConfiguration(url: workspaceDBURL)

            let container = try ModelContainer(for: schema, configurations: [config])
            return container
        } catch {
            // 如果自定义路径失败，回退到默认路径
            logWarn("使用自定义路径初始化工作区数据库失败，回退到默认路径: \(error)")

            do {
                let config = ModelConfiguration("Workspace", schema: schema)
                let container = try ModelContainer(for: schema, configurations: [config])
                return container
            } catch {
                fatalError("无法创建 Workspace ModelContainer: \(error)")
            }
        }
    }()
}

// MARK: - 工作区视图

struct WorkspaceView: View {
    var body: some View {
        WorkspaceContentView()
            .modelContainer(WorkspaceDataStore.shared)
    }
}

/// 工作区内容视图（需要 modelContext）
private struct WorkspaceContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkspaceFolder.addedAt) private var folders: [WorkspaceFolder]

    @State private var isTargeted = false
    @State private var rootNodes: [PathTreeNode] = []

    var body: some View {
        VStack(spacing: 0) {
            // 顶部安全区域（红绿灯）
            Color.clear
                .frame(height: 52)

            // 标题栏
            WorkspaceHeaderView(onAdd: selectFolder)

            Divider()

            // 主内容区
            if rootNodes.isEmpty {
                WorkspaceEmptyView(isTargeted: isTargeted)
            } else {
                WorkspaceTreeView(
                    nodes: rootNodes,
                    onRemove: removeFolder
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: folders) {
            rebuildTree()
        }
        .onAppear {
            rebuildTree()
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                // 检查是否为文件夹
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return
                }

                DispatchQueue.main.async {
                    addFolder(url.path)
                }
            }
        }
        return true
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            for url in panel.urls {
                addFolder(url.path)
            }
        }
    }

    private func addFolder(_ path: String) {
        let normalizedPath = (path as NSString).standardizingPath

        // 检查是否已存在
        guard !folders.contains(where: { $0.path == normalizedPath }) else {
            return
        }

        let folder = WorkspaceFolder(path: normalizedPath)
        modelContext.insert(folder)

    }

    private func removeFolder(_ path: String) {
        guard let folder = folders.first(where: { $0.path == path }) else { return }
        modelContext.delete(folder)

    }

    // MARK: - Tree Building

    private func rebuildTree() {
        let paths = folders.map { $0.path }

        guard !paths.isEmpty else {
            rootNodes = []
            return
        }

        // 将路径分解为组件
        let pathComponents = paths.map { path -> [String] in
            return (path as NSString).pathComponents.filter { $0 != "/" }
        }

        // 找到公共前缀
        let commonPrefix = findCommonPrefix(pathComponents)

        // 构建树
        rootNodes = buildTree(
            paths: pathComponents,
            prefixLength: commonPrefix.count,
            basePath: "/" + commonPrefix.joined(separator: "/")
        )
    }

    private func findCommonPrefix(_ paths: [[String]]) -> [String] {
        guard let first = paths.first else { return [] }
        guard paths.count > 1 else { return [] }

        var prefix: [String] = []

        for (index, component) in first.enumerated() {
            let allMatch = paths.allSatisfy { path in
                index < path.count && path[index] == component
            }

            if allMatch {
                prefix.append(component)
            } else {
                break
            }
        }

        return prefix
    }

    private func buildTree(paths: [[String]], prefixLength: Int, basePath: String) -> [PathTreeNode] {
        var groups: [String: [[String]]] = [:]

        for path in paths {
            guard prefixLength < path.count else { continue }
            let nextComponent = path[prefixLength]
            groups[nextComponent, default: []].append(path)
        }

        var nodes: [PathTreeNode] = []

        for (component, groupPaths) in groups.sorted(by: { $0.key < $1.key }) {
            let nodePath = basePath.isEmpty ? "/\(component)" : "\(basePath)/\(component)"

            if groupPaths.count == 1 && groupPaths[0].count == prefixLength + 1 {
                let node = PathTreeNode(
                    name: component,
                    fullPath: nodePath,
                    isLeaf: true
                )
                nodes.append(node)
            } else {
                let hasExactMatch = groupPaths.contains { $0.count == prefixLength + 1 }

                let children = buildTree(
                    paths: groupPaths.filter { $0.count > prefixLength + 1 },
                    prefixLength: prefixLength + 1,
                    basePath: nodePath
                )

                let node = PathTreeNode(
                    name: component,
                    fullPath: nodePath,
                    isLeaf: hasExactMatch,
                    children: children
                )
                nodes.append(node)
            }
        }

        return nodes
    }
}

// MARK: - 标题栏

private struct WorkspaceHeaderView: View {
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "folder.badge.gearshape")
                .foregroundColor(.blue)
            Text("工作区")
                .font(.headline)
            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("添加文件夹")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 空状态视图

private struct WorkspaceEmptyView: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(isTargeted ? .blue : .secondary.opacity(0.5))

            Text("拖拽文件夹到这里")
                .font(.title3)
                .foregroundColor(isTargeted ? .blue : .secondary)

            Text("或点击右上角 + 按钮添加")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.blue : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(16)
        )
    }
}

// MARK: - 树形视图

private struct WorkspaceTreeView: View {
    let nodes: [PathTreeNode]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 显示公共前缀
                if let commonPath = findCommonBasePath() {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(commonPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                    Divider()
                        .padding(.horizontal, 16)
                }

                ForEach(nodes) { node in
                    PathTreeNodeView(node: node, level: 0, onRemove: onRemove)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func findCommonBasePath() -> String? {
        guard let first = nodes.first else { return nil }
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

// MARK: - 树节点视图

private struct PathTreeNodeView: View {
    @ObservedObject var node: PathTreeNode
    let level: Int
    let onRemove: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // 展开/折叠
                if !node.children.isEmpty {
                    Button(action: { node.isExpanded.toggle() }) {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 12)
                }

                // 图标
                Image(systemName: node.isLeaf ? "folder.fill" : "folder")
                    .foregroundColor(node.isLeaf ? .blue : .secondary)
                    .font(.system(size: 14))

                // 名称
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundColor(node.isLeaf ? .primary : .secondary)

                Spacer()

                // 删除按钮
                if node.isLeaf && isHovered {
                    Button(action: { onRemove(node.fullPath) }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, CGFloat(level) * 16 + 16)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { isHovered = $0 }
            .onTapGesture(count: 2) {
                if node.isLeaf {
                    NSWorkspace.shared.open(URL(fileURLWithPath: node.fullPath))
                }
            }
            .contextMenu {
                if node.isLeaf {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.fullPath)
                    }
                    Divider()
                    Button("移除", role: .destructive) {
                        onRemove(node.fullPath)
                    }
                }
            }

            // 子节点
            if node.isExpanded {
                ForEach(node.children) { child in
                    PathTreeNodeView(node: child, level: level + 1, onRemove: onRemove)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    WorkspaceView()
        .frame(width: 300, height: 400)
}
