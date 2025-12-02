//
//  KeyboardSystem.swift
//  ETerm
//
//  应用层 - 键盘系统统一入口

import AppKit

/// 按键处理结果
enum KeyEventResult {
    case handled
    case passToIME
}

/// 键盘系统 - 统一入口
final class KeyboardSystem {

    // MARK: - Components

    let imeCoordinator: IMECoordinator
    private var inputCoordinator: InputCoordinator!
    private weak var coordinator: TerminalWindowCoordinator?

    // MARK: - State

    private var currentMode: KeyboardMode = .normal

    // MARK: - Initialization

    init(coordinator: TerminalWindowCoordinator) {
        self.coordinator = coordinator
        self.imeCoordinator = IMECoordinator()
        self.inputCoordinator = InputCoordinator(coordinator: coordinator, imeCoordinator: imeCoordinator)
    }

    // MARK: - Public API

    /// 处理键盘事件
    func handleKeyDown(_ event: NSEvent) -> KeyEventResult {
        return inputCoordinator.handleKeyDown(event)
    }

    /// 设置键盘模式
    func setMode(_ mode: KeyboardMode) {
        currentMode = mode
        inputCoordinator.setMode(mode)
    }

    /// 获取所有快捷键绑定（用于 UI 显示）
    func getAllBindings() -> [(KeyStroke, [KeyboardServiceImpl.CommandBinding])] {
        return KeyboardServiceImpl.shared.getAllBindings()
    }
}
