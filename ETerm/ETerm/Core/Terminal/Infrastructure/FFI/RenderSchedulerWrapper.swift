//
//  RenderSchedulerWrapper.swift
//  ETerm
//
//  Rust RenderScheduler 的 Swift 包装
//
//  新架构：
//  - RenderScheduler 绑定到 TerminalPool 后，在 VSync 时自动调用 pool.render_all()
//  - Swift 只需要通过 TerminalPoolWrapper.setRenderLayout() 同步布局
//  - 无需设置渲染回调，渲染完全在 Rust 侧完成
//

import Foundation

/// Rust RenderScheduler 的 Swift 包装类
///
/// 新架构：Rust 侧完成整个渲染循环
/// - bind(to:) 绑定到 TerminalPool
/// - start() 启动 CVDisplayLink
/// - requestRender() 标记需要渲染
/// - Swift 不参与渲染循环
class RenderSchedulerWrapper {

    /// Rust 侧的 handle
    private var handle: RenderSchedulerHandle?

    /// TerminalPool handle（用于绑定）
    private weak var terminalPool: TerminalPoolWrapper?

    /// 是否已启动
    private(set) var isRunning: Bool = false

    // MARK: - Initialization

    init() {
        handle = render_scheduler_create()
        if handle == nil {
            print("⚠️ [RenderSchedulerWrapper] Failed to create RenderScheduler")
        }
    }

    deinit {
        stop()
        if let handle = handle {
            render_scheduler_destroy(handle)
        }
    }

    // MARK: - Configuration

    /// 绑定到 TerminalPool（新架构）
    ///
    /// 绑定后：
    /// - RenderScheduler 和 TerminalPool 共享 needs_render 标记
    /// - RenderScheduler 在 VSync 时自动调用 pool.render_all()
    /// - 无需设置渲染回调
    func bind(to pool: TerminalPoolWrapper) {
        guard let schedulerHandle = handle,
              let poolHandle = pool.poolHandle else {
            print("⚠️ [RenderSchedulerWrapper] Invalid handles for binding")
            return
        }

        terminalPool = pool
        render_scheduler_bind_to_pool(schedulerHandle, poolHandle)
    }

    // MARK: - Control

    /// 启动渲染调度器
    func start() -> Bool {
        guard let handle = handle else {
            print("⚠️ [RenderSchedulerWrapper] No handle to start")
            return false
        }

        if isRunning {
            return true
        }

        let success = render_scheduler_start(handle)
        if success {
            isRunning = true
        } else {
            print("❌ [RenderSchedulerWrapper] Failed to start")
        }

        return success
    }

    /// 停止渲染调度器
    func stop() {
        guard let handle = handle, isRunning else { return }

        render_scheduler_stop(handle)
        isRunning = false
    }

    /// 请求渲染（标记 dirty）
    func requestRender() {
        guard let handle = handle else { return }
        render_scheduler_request_render(handle)
    }

    // MARK: - Deprecated Methods (保留用于兼容)

    /// 设置渲染回调（已废弃）
    ///
    /// 新架构下不再需要，渲染完全在 Rust 侧完成
    @available(*, deprecated, message: "New architecture: rendering is done in Rust, no callback needed")
    func setRenderCallback(_ callback: @escaping () -> Void) {
        // 新架构下不再需要此方法
        print("⚠️ [RenderSchedulerWrapper] setRenderCallback is deprecated, rendering is now done in Rust")
    }

    /// 设置渲染布局（已废弃）
    ///
    /// 新架构下应使用 TerminalPoolWrapper.setRenderLayout()
    @available(*, deprecated, message: "Use TerminalPoolWrapper.setRenderLayout() instead")
    func setLayout(_ layouts: [(terminalId: Int, x: Float, y: Float, width: Float, height: Float)]) {
        // 新架构下布局由 TerminalPool 管理
        print("⚠️ [RenderSchedulerWrapper] setLayout is deprecated, use TerminalPoolWrapper.setRenderLayout()")
    }
}
