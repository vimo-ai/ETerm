//
//  RenderSchedulerWrapper.swift
//  ETerm
//
//  Rust RenderScheduler 的 Swift 包装
//  CVDisplayLink 现在完全在 Rust 侧运行
//

import Foundation

/// Rust RenderScheduler 的 Swift 包装类
///
/// 使用 Rust 侧的 CVDisplayLink，在 VSync 时触发渲染回调
class RenderSchedulerWrapper {

    /// Rust 侧的 handle
    private var handle: RenderSchedulerHandle?

    /// TerminalPool handle（用于绑定 needs_render）
    private weak var terminalPool: TerminalPoolWrapper?

    /// 渲染回调（在主线程执行）
    private var renderCallback: (() -> Void)?

    /// 是否已启动
    private(set) var isRunning: Bool = false

    // MARK: - Initialization

    init() {
        handle = render_scheduler_create()
        if handle == nil {
            // print("⚠️ [RenderSchedulerWrapper] Failed to create RenderScheduler")
        }
    }

    deinit {
        stop()
        if let handle = handle {
            render_scheduler_destroy(handle)
        }
    }

    // MARK: - Configuration

    /// 绑定到 TerminalPool
    ///
    /// 共享 needs_render 标记，当 TerminalPool 有新内容时自动触发渲染
    func bind(to pool: TerminalPoolWrapper) {
        guard let schedulerHandle = handle,
              let poolHandle = pool.poolHandle else {
            // print("⚠️ [RenderSchedulerWrapper] Invalid handles for binding")
            return
        }

        terminalPool = pool
        render_scheduler_bind_to_pool(schedulerHandle, poolHandle)
    }

    /// 设置渲染回调
    ///
    /// 回调在 CVDisplayLink VSync 时触发（通过主线程调度）
    func setRenderCallback(_ callback: @escaping () -> Void) {
        self.renderCallback = callback

        guard let handle = handle else {
            // print("⚠️ [RenderSchedulerWrapper] No handle for setRenderCallback")
            return
        }

        // 创建一个弱引用的 context
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 设置 C 回调
        render_scheduler_set_callback(handle, { (contextPtr, layoutPtr, layoutCount) in
            guard let contextPtr = contextPtr else {
                // print("⚠️ [RenderSchedulerWrapper] Callback: contextPtr is nil")
                return
            }

            // 从 context 获取 self
            let wrapper = Unmanaged<RenderSchedulerWrapper>.fromOpaque(contextPtr).takeUnretainedValue()

            // print("🔄 [RenderSchedulerWrapper] VSync callback triggered, layoutCount: \(layoutCount)")

            // 调度到主线程执行渲染
            DispatchQueue.main.async {
                // print("🎨 [RenderSchedulerWrapper] Executing render callback on main thread")
                wrapper.renderCallback?()
            }
        }, context)

        // print("✅ [RenderSchedulerWrapper] Render callback set")
    }

    // MARK: - Control

    /// 启动渲染调度器
    func start() -> Bool {
        guard let handle = handle else {
            // print("⚠️ [RenderSchedulerWrapper] No handle to start")
            return false
        }

        if isRunning {
            return true
        }

        let success = render_scheduler_start(handle)
        if success {
            isRunning = true
            // print("✅ [RenderSchedulerWrapper] Started")
        } else {
            // print("❌ [RenderSchedulerWrapper] Failed to start")
        }

        return success
    }

    /// 停止渲染调度器
    func stop() {
        guard let handle = handle, isRunning else { return }

        render_scheduler_stop(handle)
        isRunning = false
        // print("⏹️ [RenderSchedulerWrapper] Stopped")
    }

    /// 请求渲染（标记 dirty）
    func requestRender() {
        guard let handle = handle else { return }
        render_scheduler_request_render(handle)
    }

    /// 设置渲染布局
    func setLayout(_ layouts: [(terminalId: Int, x: Float, y: Float, width: Float, height: Float)]) {
        guard let handle = handle else { return }

        var cLayouts = layouts.map { layout in
            RenderLayout(
                terminal_id: layout.terminalId,
                x: layout.x,
                y: layout.y,
                width: layout.width,
                height: layout.height
            )
        }

        cLayouts.withUnsafeMutableBufferPointer { buffer in
            render_scheduler_set_layout(handle, buffer.baseAddress, buffer.count)
        }
    }
}
