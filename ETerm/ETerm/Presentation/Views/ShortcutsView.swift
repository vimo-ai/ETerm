//
//  ShortcutsView.swift
//  ETerm
//
//  快捷键列表视图 - 显示所有注册的键盘快捷键

import SwiftUI

struct ShortcutsView: View {
    let bindings: [KeyBinding]

    /// 按分类分组的快捷键
    private var groupedBindings: [(category: String, shortcuts: [(key: String, description: String)])] {
        let grouped = Dictionary(grouping: bindings, by: { $0.category })
        return grouped.map { (category, bindings) in
            let shortcuts = bindings.map { binding in
                (key: binding.keyStroke.displayString, description: binding.description)
            }
            return (category: category, shortcuts: shortcuts)
        }
        .sorted { $0.category < $1.category }  // 按分类名称排序
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("快捷键")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            // 快捷键列表
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedBindings, id: \.category) { group in
                        ShortcutSection(
                            title: group.category,
                            shortcuts: group.shortcuts
                        )
                    }
                }
                .padding()
            }
        }
    }
}

/// 快捷键分组
struct ShortcutSection: View {
    let title: String
    let shortcuts: [(key: String, description: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            VStack(spacing: 8) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    let shortcut = shortcuts[index]
                    ShortcutRow(key: shortcut.key, description: shortcut.description)
                }
            }
        }
    }
}

/// 快捷键行
struct ShortcutRow: View {
    let key: String
    let description: String

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                )
                .frame(minWidth: 80, alignment: .center)

            Text(description)
                .font(.system(size: 13))
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

#Preview {
    // 创建示例快捷键绑定用于预览
    let sampleBindings = [
        KeyBinding(.cmd("c"), event: .copy, modes: [.normal], category: "编辑", description: "复制"),
        KeyBinding(.cmd("v"), event: .paste, modes: [.normal], category: "编辑", description: "粘贴"),
        KeyBinding(.cmd("t"), event: .createTab, modes: [.normal], category: "面板管理", description: "新建 Tab"),
    ]
    return ShortcutsView(bindings: sampleBindings)
        .frame(width: 600, height: 500)
}
