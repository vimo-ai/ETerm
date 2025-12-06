//
//  GrammarArchiveView.swift
//  ETerm
//
//  语法档案视图 - 显示所有语法错误记录
//

import SwiftUI
import SwiftData

struct GrammarArchiveView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \GrammarErrorRecord.timestamp, order: .reverse)
    private var allErrors: [GrammarErrorRecord]

    @State private var selectedCategory: String? = nil

    private var categoryStats: [(category: String, count: Int)] {
        let grouped = Dictionary(grouping: allErrors, by: { $0.category })
        return grouped.map { (category: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var filteredErrors: [GrammarErrorRecord] {
        if let category = selectedCategory {
            return allErrors.filter { $0.category == category }
        }
        return allErrors
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("语法档案")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("清空") {
                    clearAllErrors()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
            .padding()

            Divider()

            // 统计信息
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatItem(label: "总错误", value: "\(allErrors.count)", color: .blue)
                    StatItem(label: "分类数", value: "\(categoryStats.count)", color: .orange)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // 分类筛选
            if !categoryStats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // 全部按钮
                        CategoryButton(
                            title: "全部",
                            count: allErrors.count,
                            isSelected: selectedCategory == nil,
                            action: { selectedCategory = nil }
                        )

                        // 分类按钮
                        ForEach(categoryStats.prefix(10), id: \.category) { stat in
                            CategoryButton(
                                title: categoryDisplayName(stat.category),
                                count: stat.count,
                                isSelected: selectedCategory == stat.category,
                                action: { selectedCategory = stat.category }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // 错误列表
            if filteredErrors.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.green)

                    Text("没有语法错误记录")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("使用写作助手检查英文，自动记录语法错误")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredErrors) { error in
                            GrammarErrorRow(error: error)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "tense": return "时态"
        case "article": return "冠词"
        case "preposition": return "介词"
        case "subject_verb_agreement": return "主谓一致"
        case "word_order": return "词序"
        case "singular_plural": return "单复数"
        case "punctuation": return "标点"
        case "spelling": return "拼写"
        case "word_choice": return "用词"
        case "sentence_structure": return "句子结构"
        case "other": return "其他"
        default: return category
        }
    }

    private func clearAllErrors() {
        do {
            try modelContext.delete(model: GrammarErrorRecord.self)
            print("✅ 已清空所有语法错误记录")
        } catch {
            print("❌ 清空失败: \(error)")
        }
    }
}

// MARK: - 分类按钮

struct CategoryButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                Text("(\(count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 错误行

struct GrammarErrorRow: View {
    let error: GrammarErrorRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 主要信息
            HStack(alignment: .top, spacing: 12) {
                // 错误类型标记
                VStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundColor(.orange)
                }
                .frame(width: 32)

                VStack(alignment: .leading, spacing: 6) {
                    // 错误对比
                    HStack(alignment: .top, spacing: 8) {
                        // 错误文本
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("❌")
                            Text(error.original)
                                .strikethrough()
                                .foregroundColor(.red)
                        }

                        Text("→")
                            .foregroundColor(.secondary)

                        // 正确文本
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("✅")
                            Text(error.corrected)
                                .foregroundColor(.green)
                        }
                    }
                    .font(.callout)

                    // 错误类型和时间
                    HStack(spacing: 8) {
                        Text(error.errorType)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange.opacity(0.2))
                            )
                            .foregroundColor(.orange)

                        Label(
                            error.timestamp.formatted(.relative(presentation: .named)),
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // 展开按钮
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 展开内容：完整上下文
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("完整输入")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(error.inputContext)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                }
                .padding(.leading, 44)  // 对齐图标
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

#Preview {
    GrammarArchiveView()
        .modelContainer(for: [GrammarErrorRecord.self], inMemory: true)
        .frame(width: 600, height: 800)
}
