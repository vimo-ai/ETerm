//
//  ShortcutsView.swift
//  ETerm
//
//  快捷键列表视图 - 从命令系统动态读取

import SwiftUI

struct ShortcutsView: View {
    let bindings: [(KeyStroke, [KeyboardServiceImpl.CommandBinding])]
    let commands: [Command]

    init() {
        // 从命令系统读取
        self.bindings = KeyboardServiceImpl.shared.getAllBindings()
        self.commands = CommandRegistry.shared.allCommands()
    }

    /// 按分类分组的快捷键
    private var groupedShortcuts: [(category: String, shortcuts: [(key: String, title: String, when: String?)])] {
        // 将绑定和命令关联
        var categoryMap: [String: [(key: String, title: String, when: String?)]] = [:]

        for (keyStroke, commandBindings) in bindings {
            for binding in commandBindings {
                // 查找对应的命令
                guard let command = commands.first(where: { $0.id == binding.commandId }) else {
                    continue
                }

                // 从命令 ID 提取分类
                let category = extractCategory(from: command.id)

                if categoryMap[category] == nil {
                    categoryMap[category] = []
                }

                categoryMap[category]?.append((
                    key: keyStroke.displayString,
                    title: command.title,
                    when: binding.when
                ))
            }
        }

        // 排序分类
        return categoryMap.map { (category, shortcuts) in
            (category: category, shortcuts: shortcuts.sorted { $0.title < $1.title })
        }.sorted { $0.category < $1.category }
    }

    /// 从命令 ID 提取分类
    private func extractCategory(from commandId: String) -> String {
        let parts = commandId.split(separator: ".")
        guard let category = parts.first else { return "其他" }

        switch category {
        case "page": return "窗口管理 (Page)"
        case "tab", "panel": return "面板管理 (Tab)"
        case "edit", "selection": return "编辑"
        case "font": return "字体"
        case "translation": return "AI 翻译"
        case "sidebar": return "系统"
        case "terminal": return "终端"
        case "writing": return "写作助手"
        default: return String(category).capitalized
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("快捷键")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(bindings.count) 个快捷键")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // 快捷键列表
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedShortcuts, id: \.category) { group in
                        ShortcutSection(
                            title: group.category,
                            shortcuts: group.shortcuts.map { (key: $0.key, description: $0.title) }
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
    ShortcutsView()
        .frame(width: 600, height: 500)
}
