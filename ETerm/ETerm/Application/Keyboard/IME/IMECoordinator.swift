//
//  IMECoordinator.swift
//  ETerm
//
//  应用层 - IME 协调器

/// IME 协调器
///
/// 管理输入法状态
final class IMECoordinator {

    /// 是否正在预编辑
    private(set) var isComposing: Bool = false

    /// 预编辑文本
    private(set) var markedText: String = ""

    /// 开始/更新预编辑
    func setMarkedText(_ text: String) {
        isComposing = true
        markedText = text
    }

    /// 确认输入
    func commitText(_ text: String) -> String {
        isComposing = false
        markedText = ""
        return text
    }

    /// 取消预编辑
    func cancelComposition() {
        isComposing = false
        markedText = ""
    }
}
