//
//  OneLineCommandPlugin.swift
//  ETerm
//
//  一行命令插件
//
//  功能：
//  - Cmd+O 唤起命令输入框
//  - 使用当前 Tab 的工作目录执行命令
//  - 后台执行并显示结果摘要

import Foundation
import AppKit

/// 一行命令插件
///
/// 提供快速命令执行能力，无需切换到终端窗口
final class OneLineCommandPlugin: Plugin {
    // MARK: - Plugin 元信息

    static let id = "one-line-command"
    static let name = "一行命令"
    static let version = "1.0.0"

    // MARK: - 私有属性

    /// 插件上下文（弱引用避免循环引用）
    private weak var context: PluginContext?

    /// 命令输入控制器
    private var inputController: CommandInputController?

    // MARK: - 初始化

    required init() {}

    // MARK: - Plugin 生命周期

    func activate(context: PluginContext) {
        self.context = context

        // 注册命令
        registerCommands(context: context)

        // 绑定快捷键
        bindKeyboard(context: context)

        print("✅ \(Self.name) 已激活")
    }

    func deactivate() {
        // 注销命令
        context?.commands.unregister("one-line-command.show")
        context?.commands.unregister("one-line-command.hide")

        // 解绑快捷键
        context?.keyboard.unbind(.cmdShift("o"))

        // 清理资源
        inputController = nil

        print("🔌 \(Self.name) 已停用")
    }

    // MARK: - 注册命令

    private func registerCommands(context: PluginContext) {
        // 显示输入框命令
        context.commands.register(Command(
            id: "one-line-command.show",
            title: "显示一行命令输入框",
            icon: "terminal"
        ) { [weak self] ctx in
            self?.showInputPanel(ctx)
        })

        // 隐藏输入框命令
        context.commands.register(Command(
            id: "one-line-command.hide",
            title: "隐藏一行命令输入框"
        ) { [weak self] _ in
            self?.hideInputPanel()
        })
    }

    // MARK: - 绑定快捷键

    private func bindKeyboard(context: PluginContext) {
        // 绑定 Cmd+Shift+O 到显示命令
        context.keyboard.bind(.cmdShift("o"), to: "one-line-command.show", when: nil)
    }

    // MARK: - 命令处理器

    /// 显示命令输入面板
    private func showInputPanel(_ context: CommandContext) {
        guard let coordinator = context.coordinator else {
            print("⚠️ 无法显示输入框：coordinator 不可用")
            return
        }

        // 获取当前工作目录
        let cwd = coordinator.getActiveTabCwd() ?? NSHomeDirectory()

        // 创建或显示输入控制器
        if inputController == nil {
            inputController = CommandInputController(
                coordinator: coordinator,
                onExecute: { [weak self] command in
                    self?.executeCommand(command, cwd: cwd)
                },
                onCancel: { [weak self] in
                    self?.hideInputPanel()
                }
            )
        }

        inputController?.show(in: context.window, cwd: cwd)
    }

    /// 隐藏命令输入面板
    private func hideInputPanel() {
        inputController?.hide()
    }

    /// 执行命令
    private func executeCommand(_ command: String, cwd: String) {
        print("💬 执行命令: \(command) (cwd: \(cwd))")

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
            print("✅ 命令执行成功")
            // 显示结果 3 秒后自动关闭
            inputController?.showResult(output, isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.hideInputPanel()
            }

        case .failure(let error):
            print("❌ 命令执行失败: \(error)")
            // 显示错误 5 秒后自动关闭
            inputController?.showResult(error, isError: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.hideInputPanel()
            }
        }
    }
}
