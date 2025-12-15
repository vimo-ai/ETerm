//
//  VocabularyView.swift
//  ETerm
//
//  单词本视图 - 显示用户查过的所有单词
//

import SwiftUI
import SwiftData

struct VocabularyView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WordEntry.hitCount, order: .reverse)
    private var allWords: [WordEntry]

    @State private var searchText = ""
    @State private var filterMode: FilterMode = .all

    enum FilterMode: String, CaseIterable {
        case all = "全部"
        case frequent = "高频 (≥2次)"
        case new = "新单词"
    }

    private var filteredWords: [WordEntry] {
        var words = allWords

        // 按模式筛选
        switch filterMode {
        case .all:
            break
        case .frequent:
            words = words.filter { $0.hitCount >= 2 }
        case .new:
            words = words.filter { $0.hitCount == 1 }
        }

        // 搜索过滤
        if !searchText.isEmpty {
            words = words.filter {
                $0.word.localizedCaseInsensitiveContains(searchText)
            }
        }

        return words
    }

    private var statistics: (total: Int, frequent: Int, new: Int) {
        let total = allWords.count
        let frequent = allWords.filter { $0.hitCount >= 2 }.count
        let new = allWords.filter { $0.hitCount == 1 }.count
        return (total, frequent, new)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("单词本")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("导出") {
                    exportData()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // 统计信息
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatItem(label: "总单词", value: "\(statistics.total)", color: .blue)
                    StatItem(label: "高频词", value: "\(statistics.frequent)", color: .orange)
                    StatItem(label: "新单词", value: "\(statistics.new)", color: .green)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // 搜索和筛选
            VStack(spacing: 8) {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索单词...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                )

                // 筛选按钮
                HStack(spacing: 8) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Button(action: { filterMode = mode }) {
                            Text(mode.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(filterMode == mode ? Color.accentColor : Color.clear)
                                )
                                .foregroundColor(filterMode == mode ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // 单词列表
            if filteredWords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text(searchText.isEmpty ? "还没有单词" : "没有找到单词")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    if searchText.isEmpty {
                        Text("开始翻译单词，自动记录到单词本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredWords) { word in
                            WordRow(word: word)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func exportData() {
    }
}

// MARK: - 统计项

struct StatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
}

// MARK: - 单词行

struct WordRow: View {
    let word: WordEntry
    @State private var isExpanded = false

    private var hitBadgeColor: Color {
        switch word.hitCount {
        case 1: return .green
        case 2: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 主要信息
            HStack(alignment: .top, spacing: 12) {
                // Hit 次数标记
                Text("\(word.hitCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(hitBadgeColor)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    // 单词 + 音标
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(word.word)
                            .font(.headline)

                        if let phonetic = word.phonetic {
                            Text(phonetic)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 释义（中英文都显示）
                    VStack(alignment: .leading, spacing: 4) {
                        // 中文翻译
                        if let translation = word.chineseTranslation {
                            Text(translation)
                                .font(.callout)
                                .foregroundColor(.primary)
                                .lineLimit(isExpanded ? nil : 2)
                        }

                        // 英文定义
                        if let definition = word.primaryDefinition {
                            Text(definition)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .lineLimit(isExpanded ? nil : 2)
                        }
                    }

                    // 时间信息
                    HStack(spacing: 8) {
                        if let lastQuery = word.lastQueryDate {
                            Label(
                                lastQuery.formatted(.relative(presentation: .named)),
                                systemImage: "clock"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        if word.hitCount >= 2 {
                            Text("• 查询 \(word.hitCount) 次")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // 展开/收起按钮
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 展开内容
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    // 上下文
                    if let context = word.lastSourceContext {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上下文")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text(context)
                                .font(.callout)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                )
                        }
                    }

                    // 查询历史
                    if word.queryTimestamps.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("查询历史")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(Array(word.queryTimestamps.suffix(5).enumerated()), id: \.offset) { index, date in
                                HStack {
                                    Text("•")
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 44)  // 对齐 Hit 标记
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
    VocabularyView()
        .modelContainer(for: [WordEntry.self], inMemory: true)
        .frame(width: 600, height: 800)
}
