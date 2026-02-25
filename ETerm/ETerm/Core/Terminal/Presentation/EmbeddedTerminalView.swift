//
//  EmbeddedTerminalView.swift
//  ETerm
//
//  嵌入式终端视图 - 用于插件页面中显示独立终端
//
//  特点：
//  - 独立的 TerminalPool（不共享主窗口的渲染器）
//  - 简化的事件处理（只支持基本输入）
//  - 可嵌入任意 SwiftUI View
//

import SwiftUI
import AppKit
import Metal

// MARK: - Notification Names

extension Notification.Name {
    /// 向嵌入式终端写入数据
    /// userInfo: ["terminalId": Int, "data": String]
    static let embeddedTerminalWriteInput = Notification.Name("embeddedTerminalWriteInput")
}

// MARK: - SwiftUI Wrapper

/// 嵌入式终端视图（SwiftUI）
///
/// 用法：
/// ```swift
/// EmbeddedTerminalView(
///     initialCommand: "echo 'Hello'",
///     workingDirectory: "/tmp"
/// )
/// .frame(height: 300)
/// ```
struct EmbeddedTerminalView: NSViewRepresentable {
    /// 初始命令（可选，终端创建后自动执行）
    var initialCommand: String?

    /// 工作目录（可选）
    var workingDirectory: String?

    /// 终端 ID 回调（创建成功后回调）
    var onTerminalCreated: ((Int) -> Void)?

    func makeNSView(context: Context) -> EmbeddedTerminalMetalView {
        let view = EmbeddedTerminalMetalView()
        view.initialCommand = initialCommand
        view.workingDirectory = workingDirectory
        view.onTerminalCreated = onTerminalCreated
        return view
    }

    func updateNSView(_ nsView: EmbeddedTerminalMetalView, context: Context) {
        // 尺寸变化时触发重新渲染
        if nsView.bounds.width > 0 && nsView.bounds.height > 0 {
            nsView.requestRender()
        }
    }
}

// MARK: - Metal View

/// 嵌入式终端 Metal 视图
///
/// 简化版的 RioMetalView，专为插件嵌入设计
class EmbeddedTerminalMetalView: NSView {

    // MARK: - Properties

    /// 终端池（独立实例）
    private var terminalPool: TerminalPoolWrapper?

    /// 渲染调度器
    private var renderScheduler: RenderSchedulerWrapper?

    /// 当前终端 ID
    private(set) var terminalId: Int = -1

    /// 是否已初始化
    private var isInitialized = false

    /// 初始命令
    var initialCommand: String?

    /// 工作目录
    var workingDirectory: String?

    /// 外部 PTY fd（dev-runner 等外部进程管理器集成）
    /// 设置后不创建新 shell，直接复用该 fd
    var externalFd: Int32?

    /// 外部进程 PID（与 externalFd 配合使用）
    var externalChildPid: UInt32?

    /// 终端创建回调
    var onTerminalCreated: ((Int) -> Void)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.isOpaque = false
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            // 延迟初始化，确保布局完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.initialize()
            }
        }
    }

    override func layout() {
        super.layout()

        guard isInitialized, let pool = terminalPool else { return }

        let scale = window?.screen?.backingScaleFactor ?? 2.0

        if bounds.width > 0 && bounds.height > 0 {
            // 调整渲染表面大小
            pool.resizeSugarloaf(width: Float(bounds.width), height: Float(bounds.height))

            // 同步布局到 Rust
            syncLayoutToRust()
        }
    }

    // MARK: - Initialization

    private func initialize() {
        guard !isInitialized else { return }
        guard window != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        isInitialized = true

        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let scale = window?.screen?.backingScaleFactor ?? 2.0

        // 创建独立的 TerminalPoolWrapper
        terminalPool = TerminalPoolWrapper(
            windowHandle: viewPointer,
            displayHandle: viewPointer,
            width: Float(bounds.width),
            height: Float(bounds.height),
            scale: Float(scale),
            fontSize: 14.0
        )

        guard let pool = terminalPool else {
            return
        }

        // 设置渲染回调
        pool.setRenderCallback { [weak self] in
            self?.requestRender()
        }

        // 创建终端
        let cols: UInt16 = 80
        let rows: UInt16 = 24

        if let fd = externalFd, let pid = externalChildPid {
            // 外部 PTY fd 模式：复用已有 fd，不启动新 shell
            terminalId = pool.createTerminalWithFd(fd, childPid: pid, cols: cols, rows: rows)
        } else if let cwd = workingDirectory {
            terminalId = pool.createTerminalWithCwd(cols: cols, rows: rows, shell: "", cwd: cwd)
        } else {
            terminalId = pool.createTerminal(cols: cols, rows: rows, shell: "")
        }

        guard terminalId >= 0 else {
            return
        }

        // 设置外部输入监听
        setupExternalInputObserver()

        // 回调通知
        onTerminalCreated?(terminalId)

        // 启动渲染调度器
        setupRenderScheduler()

        // 执行初始命令
        if let command = initialCommand, !command.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.writeInput(command + "\n")
            }
        }

        // 初始渲染
        requestRender()
    }

    private func setupRenderScheduler() {
        guard let pool = terminalPool else { return }

        let scheduler = RenderSchedulerWrapper()
        self.renderScheduler = scheduler

        scheduler.bind(to: pool)
        _ = scheduler.start()

        syncLayoutToRust()
    }

    private func syncLayoutToRust() {
        guard isInitialized,
              let pool = terminalPool,
              terminalId >= 0 else { return }

        // 单个终端，占满整个视图
        let layouts: [(terminalId: Int, x: Float, y: Float, width: Float, height: Float)] = [
            (terminalId: terminalId, x: 0, y: 0, width: Float(bounds.width), height: Float(bounds.height))
        ]

        pool.setRenderLayout(layouts, containerHeight: Float(bounds.height))
    }

    // MARK: - Public Methods

    /// 请求渲染
    func requestRender() {
        guard isInitialized else { return }
        syncLayoutToRust()
        renderScheduler?.requestRender()
    }

    /// 写入输入
    func writeInput(_ text: String) {
        guard terminalId >= 0 else { return }
        terminalPool?.writeInput(terminalId: terminalId, data: text)
    }

    /// 清理资源
    func cleanup() {
        renderScheduler?.stop()
        renderScheduler = nil

        if terminalId >= 0 {
            terminalPool?.closeTerminal(terminalId)
        }

        terminalPool = nil
        isInitialized = false
    }

    deinit {
        cleanup()
    }

    // MARK: - Keyboard Input

    override var acceptsFirstResponder: Bool { true }

    /// 设置监听外部写入请求（通过 terminalId 匹配）
    private func setupExternalInputObserver() {
        NotificationCenter.default.addObserver(
            forName: .embeddedTerminalWriteInput,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let targetId = notification.userInfo?["terminalId"] as? Int,
                  targetId == self.terminalId,
                  let data = notification.userInfo?["data"] as? String else {
                return
            }
            self.writeInput(data)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard terminalId >= 0 else {
            super.keyDown(with: event)
            return
        }

        // 简单处理：直接发送字符
        if let characters = event.characters, !characters.isEmpty {
            writeInput(characters)
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard terminalId >= 0, let pool = terminalPool else {
            super.scrollWheel(with: event)
            return
        }

        let deltaY = event.scrollingDeltaY
        let scrollLines: Int32
        if event.hasPreciseScrollingDeltas {
            scrollLines = Int32(round(deltaY / 10.0))
        } else {
            scrollLines = Int32(deltaY * 3)
        }

        if scrollLines != 0 {
            _ = pool.scroll(terminalId: terminalId, deltaLines: scrollLines)
            requestRender()
        }
    }
}
