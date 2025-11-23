//
//  RioTerminalView.swift
//  ETerm
//
//  照抄 Rio 渲染逻辑的终端视图
//

import SwiftUI
import AppKit
import Combine
import Metal
import QuartzCore

// MARK: - RioTerminalView

struct RioTerminalView: View {
    @StateObject private var viewModel = RioTerminalViewModel()

    var body: some View {
        ZStack {
            // 背景层
            GeometryReader { geometry in
                Image("night")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.3)
            }
            .ignoresSafeArea()

            // 渲染层
            RioRenderView(viewModel: viewModel)
        }
    }
}

// MARK: - ViewModel

class RioTerminalViewModel: ObservableObject {
    @Published var updateTrigger: Int = 0

    var terminalPool: RioTerminalPoolWrapper?
    var terminalId: Int = -1
    var sugarloafHandle: SugarloafHandle?
    var richTextId: Int = 0

    /// 当前终端尺寸
    var cols: UInt16 = 80
    var rows: UInt16 = 24

    /// 字体度量
    var cellWidth: CGFloat = 8.0
    var cellHeight: CGFloat = 16.0

    init() {
        // 初始化在 NSView 创建时进行
    }

    func triggerUpdate() {
        DispatchQueue.main.async {
            self.updateTrigger += 1
        }
    }
}

// MARK: - NSViewRepresentable

struct RioRenderView: NSViewRepresentable {
    @ObservedObject var viewModel: RioTerminalViewModel

    func makeNSView(context: Context) -> RioMetalView {
        let view = RioMetalView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: RioMetalView, context: Context) {
        // 读取 updateTrigger 触发更新
        let _ = viewModel.updateTrigger
        nsView.requestRender()
    }
}

// MARK: - RioMetalView

class RioMetalView: NSView {

    weak var viewModel: RioTerminalViewModel?

    private var sugarloaf: SugarloafHandle?
    private var richTextId: Int = 0
    private var terminalPool: RioTerminalPoolWrapper?
    private var terminalId: Int = -1

    /// 字体度量（从 Sugarloaf 获取）
    private var cellWidth: CGFloat = 8.0
    private var cellHeight: CGFloat = 16.0
    private var lineHeight: CGFloat = 16.0

    /// 是否已初始化
    private var isInitialized = false

    // MARK: - 光标闪烁相关（照抄 Rio）

    private var lastBlinkToggle: Date?
    private var isBlinkingCursorVisible: Bool = true
    private var lastTypingTime: Date?
    private let blinkInterval: TimeInterval = 0.5

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// 关键：使用 CAMetalLayer 作为 backing layer
    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func commonInit() {
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.isOpaque = false  // 支持透明
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )

            if window.isKeyWindow {
                // 延迟初始化，确保 layer 已准备好
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.initialize()
                }
            }
        } else {
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc private func windowDidBecomeKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    private func initialize() {
        guard !isInitialized else { return }
        guard window != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        isInitialized = true
        initializeSugarloaf()
    }

    override func layout() {
        super.layout()

        guard isInitialized, let sugarloaf = sugarloaf else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let width = Float(bounds.width * scale)
        let height = Float(bounds.height * scale)

        if width > 0 && height > 0 {
            sugarloaf_resize(sugarloaf, width, height)

            // 重新计算终端尺寸
            if cellWidth > 0 && cellHeight > 0 {
                let newCols = UInt16(bounds.width / cellWidth)
                let newRows = UInt16(bounds.height / cellHeight)

                if let pool = terminalPool, terminalId >= 0 {
                    if newCols != viewModel?.cols || newRows != viewModel?.rows {
                        _ = pool.resize(terminalId: terminalId, cols: newCols, rows: newRows)
                        viewModel?.cols = newCols
                        viewModel?.rows = newRows
                    }
                }
            }

            requestRender()
        }
    }

    // MARK: - Sugarloaf Initialization

    private func initializeSugarloaf() {
        guard let window = window else { return }

        let scale = Float(window.backingScaleFactor)
        let width = Float(bounds.width) * scale
        let height = Float(bounds.height) * scale

        // 设置 layer 的 contentsScale
        layer?.contentsScale = window.backingScaleFactor

        // 获取 NSView 的指针（不是 layer）
        // Sugarloaf 在 Rust 侧会通过 AppKitWindowHandle 获取 layer
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)

        // 创建 Sugarloaf
        sugarloaf = sugarloaf_new(
            windowHandle,
            windowHandle,  // displayHandle 可以和 windowHandle 相同
            width,
            height,
            scale,
            14.0  // 字体大小
        )

        guard let sugarloaf = sugarloaf else {
            print("[RioMetalView] Failed to create Sugarloaf")
            return
        }

        // 创建 RichText
        richTextId = Int(sugarloaf_create_rich_text(sugarloaf))

        // 获取字体度量
        var metrics = SugarloafFontMetrics()
        if sugarloaf_get_font_metrics(sugarloaf, &metrics) {
            cellWidth = CGFloat(metrics.cell_width)
            cellHeight = CGFloat(metrics.cell_height)
            lineHeight = CGFloat(metrics.line_height)

            viewModel?.cellWidth = cellWidth
            viewModel?.cellHeight = cellHeight
        }

        // 创建终端池
        terminalPool = RioTerminalPoolWrapper(sugarloafHandle: sugarloaf)
        viewModel?.terminalPool = terminalPool
        viewModel?.sugarloafHandle = sugarloaf
        viewModel?.richTextId = richTextId

        // 设置渲染回调
        terminalPool?.onNeedsRender = { [weak self] in
            self?.requestRender()
        }

        // 创建终端
        let cols = UInt16(bounds.width / cellWidth)
        let rows = UInt16(bounds.height / cellHeight)
        terminalId = terminalPool?.createTerminal(cols: cols, rows: rows, shell: "/bin/zsh") ?? -1
        viewModel?.terminalId = terminalId
        viewModel?.cols = cols
        viewModel?.rows = rows

        print("[RioMetalView] Initialized: cols=\(cols), rows=\(rows), terminalId=\(terminalId)")

        // 初始渲染
        requestRender()
    }

    // MARK: - Rendering

    func requestRender() {
        guard isInitialized else { return }

        DispatchQueue.main.async { [weak self] in
            self?.render()
        }
    }

    /// 照抄 Rio 的渲染流程
    private func render() {
        guard let sugarloaf = sugarloaf,
              let pool = terminalPool,
              terminalId >= 0 else { return }

        // 获取终端快照 - 照抄 Rio 的 TerminalSnapshot
        guard let snapshot = pool.getSnapshot(terminalId: terminalId) else { return }

        // 获取可见行数据
        let content = self.sugarloaf!

        sugarloaf_content_sel(content, richTextId)
        sugarloaf_content_clear(content)

        // 照抄 Rio: 计算光标可见性
        let isCursorVisible = calculateCursorVisibility(snapshot: snapshot)

        // 渲染每一行
        for rowIndex in 0..<Int(snapshot.screen_lines) {
            if rowIndex > 0 {
                sugarloaf_content_new_line(content)
            }

            let cells = pool.getRowCells(terminalId: terminalId, rowIndex: rowIndex, maxCells: Int(snapshot.columns))

            // 调试：打印第一行的前 10 个字符
            if rowIndex == 0 && !cells.isEmpty {
                let preview = cells.prefix(10).compactMap {
                    UnicodeScalar($0.character).map { String(Character($0)) }
                }.joined()
                if preview.trimmingCharacters(in: .whitespaces) != "" {
                    print("[Swift render] row 0 preview: '\(preview)' (terminalId=\(terminalId), cells.count=\(cells.count))")
                }
            }

            // 照抄 Rio: create_line
            renderLine(
                content: content,
                cells: cells,
                rowIndex: rowIndex,
                snapshot: snapshot,
                isCursorVisible: isCursorVisible
            )
        }

        sugarloaf_content_build(content)
        sugarloaf_commit_rich_text(content, richTextId)
        sugarloaf_render(content)
    }

    /// 照抄 Rio: 计算光标可见性
    private func calculateCursorVisibility(snapshot: TerminalSnapshot) -> Bool {
        // 如果光标被隐藏（DECTCEM 或滚动），直接返回 false
        if snapshot.cursor_visible == 0 {
            return false
        }

        // 照抄 Rio: 光标闪烁逻辑
        if snapshot.blinking_cursor != 0 {
            let hasSelection = snapshot.has_selection != 0
            if !hasSelection {
                var shouldBlink = true

                // 如果最近有输入，暂停闪烁
                if let lastTyping = lastTypingTime, Date().timeIntervalSince(lastTyping) < 1.0 {
                    shouldBlink = false
                }

                if shouldBlink {
                    let now = Date()
                    let shouldToggle: Bool

                    if let lastBlink = lastBlinkToggle {
                        shouldToggle = now.timeIntervalSince(lastBlink) >= blinkInterval
                    } else {
                        isBlinkingCursorVisible = true
                        lastBlinkToggle = now
                        shouldToggle = false
                    }

                    if shouldToggle {
                        isBlinkingCursorVisible = !isBlinkingCursorVisible
                        lastBlinkToggle = now
                    }
                } else {
                    isBlinkingCursorVisible = true
                    lastBlinkToggle = nil
                }

                return isBlinkingCursorVisible
            } else {
                isBlinkingCursorVisible = true
                lastBlinkToggle = nil
                return true
            }
        }

        return true
    }

    /// 照抄 Rio: create_line
    private func renderLine(
        content: SugarloafHandle,
        cells: [FFICell],
        rowIndex: Int,
        snapshot: TerminalSnapshot,
        isCursorVisible: Bool
    ) {
        let cursorRow = Int(snapshot.cursor_row)
        let cursorCol = Int(snapshot.cursor_col)

        // Rio Flags 定义
        let INVERSE: UInt32 = 0x0001              // 反色 (SGR 7)
        let WIDE_CHAR: UInt32 = 0x0020            // 宽字符本身
        let WIDE_CHAR_SPACER: UInt32 = 0x0040     // 宽字符后的占位符
        let LEADING_WIDE_CHAR_SPACER: UInt32 = 0x0400  // 行末宽字符前的占位符

        for (colIndex, cell) in cells.enumerated() {
            // 跳过宽字符占位符
            let isSpacerFlag = cell.flags & (WIDE_CHAR_SPACER | LEADING_WIDE_CHAR_SPACER)
            if isSpacerFlag != 0 {
                continue
            }

            // 获取字符
            guard let scalar = UnicodeScalar(cell.character) else { continue }
            let char = String(Character(scalar))

            // 检查是否是宽字符
            let isWideChar = cell.flags & WIDE_CHAR != 0
            let glyphWidth: Float = isWideChar ? 2.0 : 1.0

            // 检查 INVERSE 标志
            let isInverse = cell.flags & INVERSE != 0

            // 获取前景色和背景色
            var fgR = Float(cell.fg_r) / 255.0
            var fgG = Float(cell.fg_g) / 255.0
            var fgB = Float(cell.fg_b) / 255.0

            var bgR = Float(cell.bg_r) / 255.0
            var bgG = Float(cell.bg_g) / 255.0
            var bgB = Float(cell.bg_b) / 255.0

            // INVERSE 处理：交换前景色和背景色
            var hasBg = false
            if isInverse {
                let origFgR = fgR, origFgG = fgG, origFgB = fgB
                fgR = bgR; fgG = bgG; fgB = bgB
                bgR = origFgR; bgG = origFgG; bgB = origFgB
                hasBg = true
            } else {
                // 检查背景色是否非默认（黑色 0,0,0）
                hasBg = bgR > 0.01 || bgG > 0.01 || bgB > 0.01
            }

            // 照抄 Rio: 光标处理
            let hasCursor = isCursorVisible && rowIndex == cursorRow && colIndex == cursorCol

            // 光标颜色（白色，可以后续配置）
            let cursorR: Float = 1.0
            let cursorG: Float = 1.0
            let cursorB: Float = 1.0
            let cursorA: Float = 0.8

            if hasCursor && snapshot.cursor_shape == 0 {  // Block cursor
                // Block 光标时，文字颜色变成背景色（黑色）
                fgR = 0.0
                fgG = 0.0
                fgB = 0.0
            }

            // 照抄 Rio: 选区处理
            if snapshot.has_selection != 0 {
                let selStartRow = Int(snapshot.selection_start_row)
                let selEndRow = Int(snapshot.selection_end_row)
                let selStartCol = Int(snapshot.selection_start_col)
                let selEndCol = Int(snapshot.selection_end_col)

                let inSelection = isInSelection(
                    row: rowIndex, col: colIndex,
                    startRow: selStartRow, startCol: selStartCol,
                    endRow: selEndRow, endCol: selEndCol
                )

                if inSelection {
                    // 选区高亮：使用特定的选区颜色
                    fgR = 1.0
                    fgG = 1.0
                    fgB = 1.0
                    hasBg = true
                    bgR = 0.3
                    bgG = 0.5
                    bgB = 0.8
                }
            }

            // 使用带背景色支持的渲染函数
            sugarloaf_content_add_text_full(
                content,
                char,
                fgR, fgG, fgB, 1.0,
                hasBg,
                bgR, bgG, bgB, 1.0,
                glyphWidth,
                hasCursor && snapshot.cursor_shape == 0,  // Block cursor
                cursorR, cursorG, cursorB, cursorA
            )
        }
    }

    /// 检查位置是否在选区内
    private func isInSelection(
        row: Int, col: Int,
        startRow: Int, startCol: Int,
        endRow: Int, endCol: Int
    ) -> Bool {
        // 归一化
        let (sRow, sCol, eRow, eCol): (Int, Int, Int, Int)
        if startRow < endRow || (startRow == endRow && startCol <= endCol) {
            (sRow, sCol, eRow, eCol) = (startRow, startCol, endRow, endCol)
        } else {
            (sRow, sCol, eRow, eCol) = (endRow, endCol, startRow, startCol)
        }

        if row < sRow || row > eRow {
            return false
        }

        if row == sRow && row == eRow {
            return col >= sCol && col <= eCol
        } else if row == sRow {
            return col >= sCol
        } else if row == eRow {
            return col <= eCol
        } else {
            return true
        }
    }

    // MARK: - 键盘输入

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        lastTypingTime = Date()
        isBlinkingCursorVisible = true
        lastBlinkToggle = nil

        guard let pool = terminalPool, terminalId >= 0 else { return }

        // 转换键盘输入为终端序列
        let inputText: String

        // 特殊键处理（keyCode 优先）
        switch event.keyCode {
        case 36:  inputText = "\r"           // Return
        case 48:  inputText = "\t"           // Tab
        case 51:  inputText = "\u{7F}"       // Delete (Backspace)
        case 53:  inputText = "\u{1B}"       // Escape
        case 117: inputText = "\u{1B}[3~"    // Forward Delete
        case 123: inputText = "\u{1B}[D"     // Left Arrow
        case 124: inputText = "\u{1B}[C"     // Right Arrow
        case 125: inputText = "\u{1B}[B"     // Down Arrow
        case 126: inputText = "\u{1B}[A"     // Up Arrow
        case 115: inputText = "\u{1B}[H"     // Home
        case 119: inputText = "\u{1B}[F"     // End
        case 116: inputText = "\u{1B}[5~"    // Page Up
        case 121: inputText = "\u{1B}[6~"    // Page Down
        default:
            // Ctrl 组合键
            if event.modifierFlags.contains(.control),
               let char = event.charactersIgnoringModifiers?.lowercased().first,
               let ascii = char.asciiValue, ascii >= 97, ascii <= 122 {
                // Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
                inputText = String(UnicodeScalar(ascii - 96))
            } else if let chars = event.characters, !chars.isEmpty {
                // 普通字符
                inputText = chars
            } else {
                return
            }
        }

        _ = pool.writeInput(terminalId: terminalId, data: inputText)
    }

    override func flagsChanged(with event: NSEvent) {
        // 处理修饰键
    }

    // MARK: - 鼠标滚动

    override func scrollWheel(with event: NSEvent) {
        guard let pool = terminalPool, terminalId >= 0 else { return }

        let deltaY = event.scrollingDeltaY
        let delta = Int32(-deltaY / 3)

        if delta != 0 {
            _ = pool.scroll(terminalId: terminalId, deltaLines: delta)
            requestRender()
        }
    }
}
