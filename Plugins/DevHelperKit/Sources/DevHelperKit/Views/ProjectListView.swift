// ProjectListView.swift
// DevHelperKit
//
// 项目列表视图

import SwiftUI

/// 项目列表视图
struct ProjectListView: View {
    @ObservedObject var viewModel: DevHelperViewModel
    @Binding var selectedScript: SelectedScript?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "hammer.fill")
                    .foregroundColor(.orange)
                Text("项目")
                    .font(.headline)
                Spacer()

                if viewModel.isScanning {
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

            if viewModel.rootNodes.isEmpty {
                EmptyProjectsView(isScanning: viewModel.isScanning)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !viewModel.commonPrefix.isEmpty && viewModel.commonPrefix != "/" {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text(viewModel.commonPrefix)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            Divider().padding(.horizontal, 12)
                        }

                        ForEach(viewModel.rootNodes) { node in
                            ProjectTreeNodeView(
                                node: node,
                                level: 0,
                                viewModel: viewModel,
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
}

/// 项目树节点视图
struct ProjectTreeNodeView: View {
    @ObservedObject var node: ProjectTreeNode
    let level: Int
    @ObservedObject var viewModel: DevHelperViewModel
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
                        viewModel: viewModel,
                        selectedScript: $selectedScript
                    )
                }
            }

            if node.isExpanded {
                ForEach(node.children) { child in
                    ProjectTreeNodeView(
                        node: child,
                        level: level + 1,
                        viewModel: viewModel,
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
