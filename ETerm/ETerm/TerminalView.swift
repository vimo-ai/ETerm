//
//  TerminalView.swift
//  ETerm
//
//  Complete terminal view with PTY + Sugarloaf rendering
//

import SwiftUI
import AppKit

/// NSView that integrates terminal PTY with Sugarloaf rendering
class TerminalNSView: NSView {
    private var sugarloaf: SugarloafWrapper?
    private var terminal: TerminalWrapper?
    private var updateTimer: Timer?
    private var scrollOffset: Int = 0  // 滚动偏移量（向上滚动的行数）

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Layer-backed view for Metal
        wantsLayer = true

        print("✅ TerminalView is layer-backed")

        // Wait for window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeKey() {
        // 延迟初始化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    private func initialize() {
        guard sugarloaf == nil, let window = window else { return }
        guard bounds.width > 0 && bounds.height > 0 else {
            print("⚠️ View bounds is zero, waiting...")
            return
        }

        print("🪟 Initializing terminal + Sugarloaf...")
        print("   Bounds: \(bounds)")
        print("   Scale: \(window.backingScaleFactor)")

        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)
        let displayHandle = windowHandle

        let scale = Float(window.backingScaleFactor)
        let width = Float(bounds.width)
        let height = Float(bounds.height)

        // 初始化 Sugarloaf
        sugarloaf = SugarloafWrapper(
            windowHandle: windowHandle,
            displayHandle: displayHandle,
            width: width,
            height: height,
            scale: scale,
            fontSize: 14.0  // 终端适中的字体大小
        )

        guard sugarloaf != nil else {
            print("❌ Failed to initialize Sugarloaf")
            return
        }

        print("✅ Sugarloaf initialized")

        // 计算终端的列数和行数（基于字体大小）
        // 假设字符宽度约为 fontSize * 0.6，高度约为 fontSize * 1.2
        let fontSize: Float = 14.0
        let charWidth = fontSize * 0.6
        let charHeight = fontSize * 1.2

        let cols = UInt16(width / charWidth)
        let rows = UInt16(height / charHeight)

        print("📐 Terminal size: \(cols)x\(rows)")

        // 初始化终端
        terminal = TerminalWrapper(cols: cols, rows: rows, shell: "/bin/zsh")

        guard terminal != nil else {
            print("❌ Failed to initialize Terminal")
            return
        }

        print("✅ Terminal initialized")

        // 启动定时器读取 PTY 输出并渲染
        startUpdateTimer()

        // 初始渲染
        renderTerminal()

        needsDisplay = true
    }

    private func startUpdateTimer() {
        // 60 FPS 更新
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateTerminal()
        }
    }

    private func updateTerminal() {
        guard let terminal = terminal else { return }

        // 读取 PTY 输出
        if terminal.readOutput() {
            // 有新数据，重置滚动到底部并重新渲染
            scrollOffset = 0
            renderTerminal()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let terminal = terminal else {
            super.scrollWheel(with: event)
            return
        }

        // 获取历史大小
        let historySize = terminal.getHistorySize()

        // 处理滚轮事件
        let delta = Int(event.scrollingDeltaY)

        if delta > 0 {
            // 向上滚动（查看历史）
            scrollOffset = min(scrollOffset + 3, historySize)
        } else if delta < 0 {
            // 向下滚动（回到底部）
            scrollOffset = max(scrollOffset - 3, 0)
        }

        // 重新渲染
        renderTerminal()
    }

    private func renderTerminal() {
        guard let sugarloaf = sugarloaf,
              let terminal = terminal else { return }

        // 清空屏幕
        sugarloaf.clear()

        // 创建 RichText
        let rtId = sugarloaf.createRichText()
        sugarloaf.selectContent(richTextId: rtId)
        sugarloaf.clearContent()

        let rows = Int(terminal.rows)
        let cols = Int(terminal.cols)

        // 渲染所有可见行（根据滚动偏移量）
        for row in 0..<rows {
            var currentLine = ""
            var currentColor: (r: UInt8, g: UInt8, b: UInt8)? = nil

            // 计算实际行号（考虑滚动偏移）
            // scrollOffset = 0 时显示最新内容（row 0 到 rows-1）
            // scrollOffset > 0 时向上滚动，显示历史（row - scrollOffset）
            let actualRow = Int32(row) - Int32(scrollOffset)

            for col in 0..<cols {
                guard let cellData = terminal.getCellWithScroll(row: actualRow, col: UInt16(col)) else {
                    continue
                }

                // 如果颜色改变了，先输出之前的文本
                if let prevColor = currentColor,
                   prevColor != cellData.fgColor {
                    if !currentLine.isEmpty {
                        let (r, g, b) = prevColor
                        sugarloaf.text(currentLine, color: (
                            Float(r) / 255.0,
                            Float(g) / 255.0,
                            Float(b) / 255.0,
                            1.0
                        ))
                        currentLine = ""
                    }
                }

                // 累积相同颜色的字符
                currentLine.append(cellData.char)
                currentColor = cellData.fgColor
            }

            // 输出这一行剩余的文本（移除尾部空格）
            if !currentLine.isEmpty, let color = currentColor {
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let (r, g, b) = color
                    sugarloaf.text(trimmed, color: (
                        Float(r) / 255.0,
                        Float(g) / 255.0,
                        Float(b) / 255.0,
                        1.0
                    ))
                }
            }

            // 换行（除了最后一行）
            if row < rows - 1 {
                sugarloaf.line()
            }
        }

        sugarloaf.build()
        sugarloaf.commitRichText(id: rtId)

        // 渲染
        sugarloaf.render()
    }

    override func keyDown(with event: NSEvent) {
        guard let terminal = terminal else {
            super.keyDown(with: event)
            return
        }

        // 处理键盘输入
        if let characters = event.characters {
            print("[TerminalView] Key pressed: \(characters)")

            // 处理特殊键
            if event.modifierFlags.contains(.control) && characters == "c" {
                // Ctrl+C
                terminal.writeInput("\u{03}")
                return
            }

            // 处理回车
            if event.keyCode == 36 {  // Return key
                terminal.writeInput("\r")
                return
            }

            // 处理退格
            if event.keyCode == 51 {  // Delete key
                terminal.writeInput("\u{7F}")
                return
            }

            // 普通字符
            terminal.writeInput(characters)
        }
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func layout() {
        super.layout()

        // 窗口大小改变时重新渲染
        if sugarloaf != nil && terminal != nil {
            renderTerminal()
        }
    }

    deinit {
        updateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        print("[TerminalView] Cleaned up")
    }
}

/// SwiftUI wrapper for TerminalNSView
struct TerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView()
        return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // 更新视图时的逻辑
    }
}

// MARK: - Preview
struct TerminalView_Previews: PreviewProvider {
    static var previews: some View {
        TerminalView()
            .frame(width: 800, height: 600)
    }
}
