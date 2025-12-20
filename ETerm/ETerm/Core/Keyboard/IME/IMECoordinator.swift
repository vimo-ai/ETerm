//
//  IMECoordinator.swift
//  ETerm
//
//  应用层 - IME 协调器

/// IME 协调器
///
/// 管理输入法状态，同步到 Rust 渲染层
final class IMECoordinator {

    /// 是否正在预编辑
    private(set) var isComposing: Bool = false

    /// 预编辑文本
    private(set) var markedText: String = ""

    // MARK: - Rust 层回调

    /// 当预编辑文本变化时调用（用于同步到 Rust 渲染）
    /// 参数：(text, cursorOffset)
    var onPreeditChange: ((String, UInt32) -> Void)?

    /// 当预编辑清除时调用
    var onPreeditClear: (() -> Void)?

    // MARK: - IME 操作

    /// 开始/更新预编辑
    /// - Parameters:
    ///   - text: 预编辑文本
    ///   - cursorOffset: 预编辑内光标偏移（grapheme 索引）
    func setMarkedText(_ text: String, cursorOffset: UInt32 = 0) {
        isComposing = true
        markedText = text

        // 同步到 Rust 渲染层
        onPreeditChange?(text, cursorOffset)
    }

    /// 确认输入
    func commitText(_ text: String) -> String {
        isComposing = false
        markedText = ""

        // 清除 Rust 层预编辑
        onPreeditClear?()

        return text
    }

    /// 取消预编辑
    func cancelComposition() {
        isComposing = false
        markedText = ""

        // 清除 Rust 层预编辑
        onPreeditClear?()
    }
}
