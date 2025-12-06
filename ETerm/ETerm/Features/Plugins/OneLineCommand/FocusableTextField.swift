//
//  FocusableTextField.swift
//  ETerm
//
//  可聚焦的 TextField（使用 NSTextField 实现）

import SwiftUI
import AppKit

/// 可聚焦的 TextField
///
/// 使用 NSViewRepresentable 包装原生 NSTextField，
/// 解决 SwiftUI TextField 在 Panel 中无法自动聚焦的问题
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusableNSTextField()
        textField.placeholderString = placeholder
        textField.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.delegate = context.coordinator

        return textField
    }

    // 自定义 NSTextField，积极尝试获取焦点
    class FocusableNSTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            // 立即尝试获取焦点
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }

            // 多次尝试，确保成功
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        // 积极接受第一响应者状态
        override var acceptsFirstResponder: Bool {
            return true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            print("🔍 [FocusableTextField] becomeFirstResponder: \(result)")
            return result
        }
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField

        init(_ parent: FocusableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Enter 键
                parent.onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Esc 键
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
