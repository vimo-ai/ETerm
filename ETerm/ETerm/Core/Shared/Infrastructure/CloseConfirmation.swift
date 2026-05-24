import AppKit

enum CloseConfirmation {

    /// 关闭有运行进程的终端前确认
    static func confirmCloseWithProcess(processName: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "终端正在运行 \(processName)"
        alert.informativeText = "关闭此终端将终止正在运行的进程，确定要继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    /// 关闭窗口/退出应用前确认
    static func confirmCloseWindow(isLastWindow: Bool, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()

        if isLastWindow {
            alert.messageText = "确定要退出 ETerm 吗？"
            alert.informativeText = "这是最后一个窗口，关闭后将退出应用程序。"
            alert.addButton(withTitle: "退出")
        } else {
            alert.messageText = "确定要关闭此窗口吗？"
            alert.informativeText = "窗口中的所有终端会话将被关闭。"
            alert.addButton(withTitle: "关闭")
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    /// 安全退出应用（设置标记防止 windowShouldClose 再弹确认）
    static func terminateApp() {
        WindowManager.shared.isTerminating = true
        NSApplication.shared.terminate(nil)
    }
}
