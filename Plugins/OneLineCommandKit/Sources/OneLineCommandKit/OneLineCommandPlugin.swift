//
//  OneLineCommandPlugin.swift
//  OneLineCommandKit
//
//  一行命令插件 - SDK 版本
//
//  功能：
//  - Cmd+Shift+O 唤起命令输入框
//  - 使用当前 Tab 的工作目录执行命令
//  - 后台执行并显示结果摘要

import Foundation
import AppKit
import ETermKit

/// 一行命令插件
///
/// 提供快速命令执行能力，无需切换到终端窗口
@objc(OneLineCommandPlugin)
@MainActor
public final class OneLineCommandPlugin: NSObject, Plugin {
    // MARK: - Plugin 元信息

    public static let id = "one-line-command"

    // MARK: - 私有属性

    /// HostBridge（弱引用避免循环引用）
    private weak var host: HostBridge?

    /// 命令输入控制器
    private var inputController: CommandInputController?

    // MARK: - 初始化

    public override required init() {
        super.init()
    }

    // MARK: - Plugin 生命周期

    public func activate(host: HostBridge) {
        self.host = host
    }

    public func deactivate() {
        // 清理资源
        inputController?.hide()
        inputController = nil
    }

    // MARK: - 命令处理

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "one-line-command.show":
            showInputPanel()
        case "one-line-command.hide":
            hideInputPanel()
        default:
            break
        }
    }

    // MARK: - 私有方法

    /// 显示命令输入面板
    private func showInputPanel() {
        guard let host = host else { return }

        // 获取当前工作目录
        let cwd = host.getActiveTabCwd() ?? NSHomeDirectory()

        // 获取窗口 frame
        let windowFrame = host.getKeyWindowFrame()

        // 创建或显示输入控制器
        if inputController == nil {
            inputController = CommandInputController(
                onExecute: { [weak self] command in
                    self?.executeCommand(command, cwd: cwd)
                },
                onCancel: { [weak self] in
                    self?.hideInputPanel()
                }
            )
        }

        inputController?.show(windowFrame: windowFrame, cwd: cwd)
    }

    /// 隐藏命令输入面板
    private func hideInputPanel() {
        inputController?.hide()
    }

    /// 执行命令
    private func executeCommand(_ command: String, cwd: String) {
        // 执行命令
        ImmediateExecutor.execute(command, cwd: cwd) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleExecutionResult(result)
            }
        }
    }

    /// 处理执行结果
    private func handleExecutionResult(_ result: CommandExecutionResult) {
        switch result {
        case .success(let output):
            // 显示结果 3 秒后自动关闭
            inputController?.showResult(output, isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.hideInputPanel()
            }

        case .failure(let error):
            // 显示错误 5 秒后自动关闭
            inputController?.showResult(error, isError: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.hideInputPanel()
            }
        }
    }
}
