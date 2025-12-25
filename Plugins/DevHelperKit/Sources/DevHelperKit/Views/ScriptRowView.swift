// ScriptRowView.swift
// DevHelperKit
//
// 脚本行视图

import SwiftUI

/// 脚本行视图
struct ScriptRowView: View {
    let script: ProjectScript
    let project: DetectedProject
    let level: Int
    @ObservedObject var viewModel: DevHelperViewModel
    @Binding var selectedScript: SelectedScript?

    @State private var isHovered = false

    private var isRunning: Bool {
        viewModel.isRunning(projectPath: project.path, scriptName: script.name)
    }

    private var isSelected: Bool {
        selectedScript?.projectId == project.id && selectedScript?.scriptId == script.id
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
