//
//  TabManagerWrapper.swift
//  ETerm
//
//  Tab Manager 的 Swift 封装
//

import Foundation

/// Tab Manager 的 Swift 封装
class TabManagerWrapper {
    private(set) var handle: TabManagerHandle?
    // 保持对回调的强引用,防止被释放
    private var renderCallbackClosure: (() -> Void)?

    init?(sugarloaf: SugarloafWrapper, cols: UInt16, rows: UInt16, shell: String) {
        guard let sugarloafHandle = sugarloaf.handle else { return nil }

        handle = shell.withCString { shellPtr in
            tab_manager_new(sugarloafHandle, cols, rows, shellPtr)
        }

        guard handle != nil else { return nil }
    }

    /// 设置渲染回调
    /// - Parameter callback: 当 PTY 有新数据时会被调用(在 Rust 线程中)
    func setRenderCallback(_ callback: @escaping () -> Void) {
        guard let handle = handle else { return }

        // 保持对闭包的强引用
        self.renderCallbackClosure = callback

        // 将 self 作为 context 传递
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 设置 C 回调函数
        tab_manager_set_render_callback(handle, { contextPtr in
            guard let contextPtr = contextPtr else { return }

            // 从 context 恢复 TabManagerWrapper 实例
            let wrapper = Unmanaged<TabManagerWrapper>.fromOpaque(contextPtr).takeUnretainedValue()

            // 在主线程调用 Swift 闭包
            DispatchQueue.main.async {
                wrapper.renderCallbackClosure?()
            }
        }, context)
    }

    deinit {
        if let handle = handle {
            tab_manager_free(handle)
        }
    }

    /// 创建新 Tab
    @discardableResult
    func createTab() -> Int {
        guard let handle = handle else { return -1 }
        return Int(tab_manager_create_tab(handle))
    }

    /// 切换 Tab
    func switchTab(_ tabId: Int) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_switch_tab(handle, tabId) != 0
    }

    /// 关闭 Tab
    func closeTab(_ tabId: Int) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_close_tab(handle, tabId) != 0
    }

    /// 获取当前激活的 Tab ID
    func getActiveTab() -> Int {
        guard let handle = handle else { return -1 }
        return Int(tab_manager_get_active_tab(handle))
    }

    /// 读取所有 Tab 的输出
    func readAllTabs() -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_read_all_tabs(handle) != 0
    }

    /// 渲染当前激活的 Tab
    func renderActiveTab() -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_render_active_tab(handle) != 0
    }

    /// 向当前激活的 Tab 写入输入
    func writeInput(_ input: String) -> Bool {
        guard let handle = handle else { return false }
        return input.withCString { dataPtr in
            tab_manager_write_input(handle, dataPtr) != 0
        }
    }

    /// 滚动当前激活的 Tab
    func scrollActiveTab(_ deltaLines: Int32) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_scroll_active_tab(handle, deltaLines) != 0
    }

    /// 调整所有 Tab 的大小
    func resizeAllTabs(cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_resize_all_tabs(handle, cols, rows) != 0
    }

    /// 获取 Tab 数量
    func getTabCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(tab_manager_get_tab_count(handle))
    }

    /// 获取所有 Tab ID
    func getTabIds() -> [Int] {
        guard let handle = handle else { return [] }

        let count = getTabCount()
        guard count > 0 else { return [] }

        var ids = [Int](repeating: 0, count: count)
        let actualCount = ids.withUnsafeMutableBufferPointer { buffer in
            tab_manager_get_tab_ids(handle, buffer.baseAddress, count)
        }

        return Array(ids.prefix(Int(actualCount)))
    }

    /// 设置 Tab 标题
    func setTabTitle(_ tabId: Int, title: String) -> Bool {
        guard let handle = handle else { return false }
        return title.withCString { titlePtr in
            tab_manager_set_tab_title(handle, tabId, titlePtr) != 0
        }
    }

    /// 获取 Tab 标题
    func getTabTitle(_ tabId: Int) -> String? {
        guard let handle = handle else { return nil }

        var buffer = [CChar](repeating: 0, count: 256)
        let success = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            tab_manager_get_tab_title(handle, tabId, bufferPtr.baseAddress, 256) != 0
        }

        guard success else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Split Pane Methods

    /// 垂直分割（左右）
    @discardableResult
    func splitRight() -> Int {
        guard let handle = handle else { return -1 }
        return Int(tab_manager_split_right(handle))
    }

    /// 水平分割（上下）
    @discardableResult
    func splitDown() -> Int {
        guard let handle = handle else { return -1 }
        return Int(tab_manager_split_down(handle))
    }

    /// 关闭指定 pane
    func closePane(_ paneId: Int) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_close_pane(handle, paneId) != 0
    }

    /// 设置激活的 pane
    func setActivePane(_ paneId: Int) -> Bool {
        guard let handle = handle else { return false }
        return tab_manager_set_active_pane(handle, paneId) != 0
    }

    /// 获取当前 Tab 的 pane 数量
    func getPaneCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(tab_manager_get_pane_count(handle))
    }
}
