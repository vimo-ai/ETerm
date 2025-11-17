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

    init?(sugarloaf: SugarloafWrapper, cols: UInt16, rows: UInt16, shell: String) {
        guard let sugarloafHandle = sugarloaf.handle else { return nil }

        handle = shell.withCString { shellPtr in
            tab_manager_new(sugarloafHandle, cols, rows, shellPtr)
        }

        guard handle != nil else { return nil }
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
}
