//
//  InputState.swift
//  ETerm - IME 输入状态值对象
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

/// IME 输入状态（不可变）
///
/// 用于管理输入法的预编辑文本（preedit）和组合状态
struct InputState: Equatable {
    /// 预编辑文本（拼音）
    /// 例如：输入 "nihao" 时，preeditText 为 "nihao"
    let preeditText: String

    /// preedit 内光标位置（字符索引，从 0 开始）
    let preeditCursor: Int

    /// 是否在输入法组合中
    /// true = 正在输入拼音/假名等，还未确认
    /// false = 已确认或未在输入
    let isComposing: Bool

    /// 创建输入状态
    init(preeditText: String, preeditCursor: Int, isComposing: Bool) {
        self.preeditText = preeditText
        self.preeditCursor = preeditCursor
        self.isComposing = isComposing
    }

    /// 空状态（无输入）
    static func empty() -> InputState {
        InputState(preeditText: "", preeditCursor: 0, isComposing: false)
    }

    /// 是否为空（无预编辑文本）
    var isEmpty: Bool {
        preeditText.isEmpty
    }

    // MARK: - 不可变转换方法

    /// 设置预编辑文本
    func withPreedit(text: String, cursor: Int) -> InputState {
        InputState(
            preeditText: text,
            preeditCursor: cursor,
            isComposing: !text.isEmpty
        )
    }

    /// 清除预编辑文本
    func clearPreedit() -> InputState {
        .empty()
    }

    /// 开始组合（进入输入法模式）
    func startComposing(with text: String = "", cursor: Int = 0) -> InputState {
        InputState(
            preeditText: text,
            preeditCursor: cursor,
            isComposing: true
        )
    }

    /// 结束组合（退出输入法模式）
    func endComposing() -> InputState {
        .empty()
    }
}

// MARK: - CustomStringConvertible
extension InputState: CustomStringConvertible {
    var description: String {
        if isEmpty {
            return "InputState(empty)"
        } else {
            return "InputState(preedit: \"\(preeditText)\", cursor: \(preeditCursor), composing: \(isComposing))"
        }
    }
}
