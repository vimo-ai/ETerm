//
//  CustomSidebar.swift
//  ETerm
//
//  自定义侧边栏 - 设置和插件入口
//

import SwiftUI

/// 侧边栏项目类型
enum SidebarItemType: Identifiable, Hashable {
    case builtin(BuiltinItem)
    case plugin(String)  // Plugin Tab ID

    var id: String {
        switch self {
        case .builtin(let item):
            return "builtin-\(item.rawValue)"
        case .plugin(let tabId):
            return "plugin-\(tabId)"
        }
    }

    enum BuiltinItem: String {
        case settings = "设置"
        case shortcuts = "快捷键"
        case plugins = "插件管理"

        var icon: String {
            switch self {
            case .settings:
                return "gearshape"
            case .shortcuts:
                return "command"
            case .plugins:
                return "puzzlepiece.extension"
            }
        }
    }
}

/// 自定义侧边栏视图（悬浮圆角半透明样式）
struct CustomSidebar: View {
    @Binding var selectedItem: SidebarItemType?
    let onClose: () -> Void
    @ObservedObject var registry = SidebarRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("ETerm")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // 侧边栏列表
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // 内置项
                    SidebarItemRow(
                        title: "设置",
                        icon: "gearshape",
                        shortcut: ",",
                        isSelected: selectedItem == .builtin(.settings),
                        action: { selectedItem = .builtin(.settings) }
                    )

                    SidebarItemRow(
                        title: "快捷键",
                        icon: "command",
                        shortcut: nil,
                        isSelected: selectedItem == .builtin(.shortcuts),
                        action: { selectedItem = .builtin(.shortcuts) }
                    )

                    SidebarItemRow(
                        title: "插件管理",
                        icon: "puzzlepiece.extension",
                        shortcut: nil,
                        isSelected: selectedItem == .builtin(.plugins),
                        action: { selectedItem = .builtin(.plugins) }
                    )

                    // 插件注册的 Tab（分组显示）
                    if !registry.allTabGroups.isEmpty {
                        Divider()
                            .padding(.vertical, 8)

                        ForEach(registry.allTabGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                // 插件标题（不可点击）
                                Text(group.pluginName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)

                                // 该插件的 Tabs
                                ForEach(group.tabs) { tab in
                                    SidebarItemRow(
                                        title: tab.title,
                                        icon: tab.icon,
                                        shortcut: nil,
                                        isSelected: selectedItem == .plugin(tab.id),
                                        action: { selectedItem = .plugin(tab.id) },
                                        isSubItem: true
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(width: 200)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))  // macOS 15+ 官方 Liquid Glass 效果
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
        .padding()  // 外部留白
    }
}

/// 侧边栏项目行
struct SidebarItemRow: View {
    let title: String
    let icon: String
    let shortcut: String?  // 快捷键（如 ","）
    let isSelected: Bool
    let action: () -> Void
    let isSubItem: Bool  // 是否为子项（缩进显示）

    // 为了向后兼容，提供默认值
    init(
        title: String,
        icon: String,
        shortcut: String?,
        isSelected: Bool,
        action: @escaping () -> Void,
        isSubItem: Bool = false
    ) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isSelected = isSelected
        self.action = action
        self.isSubItem = isSubItem
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 子项缩进
                if isSubItem {
                    Spacer()
                        .frame(width: 12)
                }

                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .white : .primary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)

                Spacer()

                // 快捷键提示
                if let shortcut = shortcut {
                    HStack(spacing: 2) {
                        Text("⌘")
                            .font(.system(size: 11, weight: .medium))
                        Text(shortcut)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.white.opacity(0.2) : Color.gray.opacity(0.15))
                    )
                }
            }
            .padding(.horizontal, isSubItem ? 8 : 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CustomSidebar(
        selectedItem: .constant(.builtin(.settings)),
        onClose: {}
    )
    .frame(height: 400)
}
