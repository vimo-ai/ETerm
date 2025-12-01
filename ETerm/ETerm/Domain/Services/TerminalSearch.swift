//
//  TerminalSearch.swift
//  ETerm
//
//  终端内容搜索引擎
//

import Foundation

/// 搜索匹配项
struct SearchMatch: Equatable {
    /// 真实行号（绝对坐标系统）
    /// 注意：使用真实行号，不随滚动变化
    let absoluteRow: Int64
    let startCol: Int
    let endCol: Int
    let text: String
}

/// 终端搜索引擎
class TerminalSearch {
    private let terminalManager: GlobalTerminalManager

    init(terminalManager: GlobalTerminalManager = .shared) {
        self.terminalManager = terminalManager
    }

    /// 在指定终端中搜索文本
    ///
    /// - Parameters:
    ///   - pattern: 搜索关键词
    ///   - terminalId: 终端 ID
    ///   - caseSensitive: 是否区分大小写
    ///   - maxRows: 最大搜索行数（默认 1000 行）
    /// - Returns: 匹配项列表
    func search(
        pattern: String,
        in terminalId: Int,
        caseSensitive: Bool = false,
        maxRows: Int = 1000
    ) -> [SearchMatch] {
        guard !pattern.isEmpty else { return [] }

        // 获取终端快照以确定行数
        guard let snapshot = terminalManager.getSnapshot(terminalId: terminalId) else {
            return []
        }

        let scrollbackLines = Int64(snapshot.scrollback_lines)
        let screenLines = Int64(snapshot.screen_lines)

        // 搜索范围：从历史缓冲区开始到当前屏幕结束
        // absoluteRow 范围: [0, scrollback_lines + screen_lines - 1]
        let totalRows = scrollbackLines + screenLines

        // 限制搜索行数，避免性能问题
        let rowsToSearch = min(Int(totalRows), maxRows)

        var matches: [SearchMatch] = []

        // 转换搜索模式（处理大小写）
        let searchPattern = caseSensitive ? pattern : pattern.lowercased()

        // 从最旧的历史开始遍历（absoluteRow = 0）
        for absoluteRow in 0..<rowsToSearch {
            let cells = terminalManager.getRowCells(
                terminalId: terminalId,
                absoluteRow: Int64(absoluteRow),
                maxCells: Int(snapshot.columns)
            )

            guard !cells.isEmpty else { continue }

            // 将单元格转换为字符串
            let lineText = cells.map { cell in
                guard let scalar = UnicodeScalar(cell.character) else { return " " }
                return String(Character(scalar))
            }.joined()

            // 搜索文本（处理大小写）
            let textToSearch = caseSensitive ? lineText : lineText.lowercased()

            // 查找所有匹配位置
            var searchStartIndex = textToSearch.startIndex
            while let range = textToSearch.range(
                of: searchPattern,
                range: searchStartIndex..<textToSearch.endIndex
            ) {
                let startCol = textToSearch.distance(from: textToSearch.startIndex, to: range.lowerBound)
                let endCol = textToSearch.distance(from: textToSearch.startIndex, to: range.upperBound) - 1

                let matchText = String(lineText[range])

                matches.append(SearchMatch(
                    absoluteRow: Int64(absoluteRow),
                    startCol: startCol,
                    endCol: endCol,
                    text: matchText
                ))

                // 移动到下一个搜索起点
                searchStartIndex = range.upperBound
            }
        }

        return matches
    }

    /// 异步搜索（用于大量数据）
    ///
    /// - Parameters:
    ///   - pattern: 搜索关键词
    ///   - terminalId: 终端 ID
    ///   - caseSensitive: 是否区分大小写
    ///   - maxRows: 最大搜索行数（默认 1000 行）
    /// - Returns: 匹配项列表
    func searchAsync(
        pattern: String,
        in terminalId: Int,
        caseSensitive: Bool = false,
        maxRows: Int = 1000
    ) async -> [SearchMatch] {
        // 在后台线程执行搜索
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return [] }
            return self.search(
                pattern: pattern,
                in: terminalId,
                caseSensitive: caseSensitive,
                maxRows: maxRows
            )
        }.value
    }
}
