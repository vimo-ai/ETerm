//
//  WorkspaceViewProvider.swift
//  WorkspaceKit
//
//  ViewProvider - 提供 SwiftUI View 给主进程

import Foundation
import SwiftUI
import ETermKit
import UniformTypeIdentifiers

/// Workspace ViewProvider
@objc(WorkspaceViewProvider)
public final class WorkspaceViewProvider: NSObject, PluginViewProvider {

    public required override init() {
        super.init()
        print("[WorkspaceViewProvider] Initialized")
    }

    @MainActor
    public func view(for tabId: String) -> AnyView {
        print("[WorkspaceViewProvider] Creating sidebar view for tab: \(tabId)")

        switch tabId {
        case "workspace-entry":
            return AnyView(WorkspaceView())
        default:
            return AnyView(
                Text("Unknown tab: \(tabId)")
                    .foregroundColor(.secondary)
            )
        }
    }
}

// MARK: - Path Tree Node

/// 路径树节点
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

// MARK: - ViewModel

/// Workspace View State
final class WorkspaceViewState: ObservableObject {
    @Published var folderCount: Int = 0
    @Published var folders: [[String: Any]] = []
    @Published var rootNodes: [PathTreeNode] = []
    @Published var commonPrefix: String = ""

    private var observer: Any?

    func startListening() {
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.UpdateViewModel"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUpdate(notification)
        }

        // 请求初始数据
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.PluginRequest"),
            object: nil,
            userInfo: [
                "pluginId": "com.eterm.workspace",
                "requestId": "getFolders",
                "params": [String: Any]()
            ]
        )
    }

    func stopListening() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func handleUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let pluginId = userInfo["pluginId"] as? String,
              pluginId == "com.eterm.workspace",
              let data = userInfo["data"] as? [String: Any] else {
            return
        }

        if let count = data["folderCount"] as? Int {
            folderCount = count
        }
        if let folderList = data["folders"] as? [[String: Any]] {
            folders = folderList
        }
        if let prefix = data["commonPrefix"] as? String {
            commonPrefix = prefix
        }
        if let tree = data["tree"] as? [[String: Any]] {
            rootNodes = parseTree(tree)
        }
    }

    private func parseTree(_ tree: [[String: Any]]) -> [PathTreeNode] {
        return tree.compactMap { parseNode($0) }
    }

    private func parseNode(_ data: [String: Any]) -> PathTreeNode? {
        guard let name = data["name"] as? String,
              let fullPath = data["fullPath"] as? String else {
            return nil
        }

        let isLeaf = data["isLeaf"] as? Bool ?? false
        let childrenData = data["children"] as? [[String: Any]] ?? []
        let children = childrenData.compactMap { parseNode($0) }

        return PathTreeNode(
            name: name,
            fullPath: fullPath,
            isLeaf: isLeaf,
            children: children
        )
    }

    func addFolder(_ path: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.PluginRequest"),
            object: nil,
            userInfo: [
                "pluginId": "com.eterm.workspace",
                "requestId": "addFolder",
                "params": ["path": path]
            ]
        )
    }

    func removeFolder(_ path: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.PluginRequest"),
            object: nil,
            userInfo: [
                "pluginId": "com.eterm.workspace",
                "requestId": "removeFolder",
                "params": ["path": path]
            ]
        )
    }
}

// MARK: - Workspace View

struct WorkspaceView: View {
    @StateObject private var viewModel = WorkspaceViewState()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            WorkspaceHeaderView(onAdd: selectFolder)

            Divider()

            // 主内容区
            if viewModel.rootNodes.isEmpty {
                WorkspaceEmptyView(isTargeted: isTargeted)
            } else {
                WorkspaceTreeView(
                    nodes: viewModel.rootNodes,
                    commonPrefix: viewModel.commonPrefix,
                    onRemove: viewModel.removeFolder
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            viewModel.startListening()
        }
        .onDisappear {
            viewModel.stopListening()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return
                }

                DispatchQueue.main.async {
                    viewModel.addFolder(url.path)
                }
            }
        }
        return true
    }

    private func selectFolder() {
        print("[WorkspaceView] selectFolder called")
        print("[WorkspaceView] keyWindow: \(String(describing: NSApp.keyWindow))")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要添加到工作区的文件夹"
        panel.prompt = "添加"

        // 使用 runModal，因为 beginSheetModal 在某些情况下不可靠
        let vm = viewModel
        DispatchQueue.main.async {
            let response = panel.runModal()
            if response == .OK {
                for url in panel.urls {
                    print("[WorkspaceView] Adding folder: \(url.path)")
                    vm.addFolder(url.path)
                }
            }
        }
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

            Image(systemName: "plus")
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture { onAdd() }
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
    let commonPrefix: String
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 显示公共前缀
                if !commonPrefix.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(commonPrefix)
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
                // 展开/折叠图标
                if !node.children.isEmpty {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
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
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { isHovered = $0 }
            .onTapGesture {
                // 单击：展开/折叠
                if !node.children.isEmpty {
                    node.isExpanded.toggle()
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
