//
//  SugarloafWrapper.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

import Foundation
import AppKit

/// Swift wrapper for Sugarloaf C FFI
class SugarloafWrapper {
    var handle: SugarloafHandle?  // 公开 handle 供 TerminalWrapper 使用
    private(set) var fontMetrics: SugarloafFontMetrics?

    init?(windowHandle: UnsafeMutableRawPointer,
          displayHandle: UnsafeMutableRawPointer,
          width: Float,
          height: Float,
          scale: Float,
          fontSize: Float) {
        handle = sugarloaf_new(windowHandle, displayHandle, width, height, scale, fontSize)
        guard handle != nil else {
            return nil
        }

        refreshFontMetrics()
    }

    deinit {
        if let handle = handle {
            sugarloaf_free(handle)
        }
    }

    /// 创建新的富文本状态
    @discardableResult
    func createRichText() -> Int {
        guard let handle = handle else { return 0 }
        return sugarloaf_create_rich_text(handle)
    }

    /// 选择富文本状态
    func selectContent(richTextId: Int) {
        guard let handle = handle else { return }
        sugarloaf_content_sel(handle, richTextId)
    }

    /// 清空内容
    func clearContent() {
        guard let handle = handle else { return }
        sugarloaf_content_clear(handle)
    }

    /// 添加新行
    func newLine() {
        guard let handle = handle else { return }
        sugarloaf_content_new_line(handle)
    }

    /// 添加文本
    func addText(_ text: String, color: (r: Float, g: Float, b: Float, a: Float) = (1.0, 1.0, 1.0, 1.0)) {
        guard let handle = handle else { return }
        text.withCString { cStr in
            sugarloaf_content_add_text(handle, cStr, color.r, color.g, color.b, color.a)
        }
    }

    /// 构建内容
    func buildContent() {
        guard let handle = handle else { return }
        sugarloaf_content_build(handle)
    }

    /// 提交富文本对象用于渲染
    func commitRichText(id: Int) {
        guard let handle = handle else { return }
        sugarloaf_commit_rich_text(handle, id)
    }

    /// 清空屏幕
    func clear() {
        guard let handle = handle else { return }
        sugarloaf_clear(handle)
    }

    /// 设置测试对象 (Quads)
    func setTestObjects() {
        guard let handle = handle else { return }
        sugarloaf_set_test_objects(handle)
    }

    /// 渲染
    func render() {
        guard let handle = handle else {
            return
        }
        sugarloaf_render(handle)
    }

    /// 调整渲染表面大小 (像素)
    func resize(width: Float, height: Float) {
        guard let handle = handle else { return }
        sugarloaf_resize(handle, width, height)
    }

    /// 重新缩放 (DPI 变化)
    func rescale(scale: Float) {
        guard let handle = handle else { return }
        sugarloaf_rescale(handle, scale)
    }

    /// 调用纯 Rust 的富文本 demo
    func renderRustDemo() {
        guard let handle = handle else {
            return
        }
        sugarloaf_render_demo(handle)
    }

    func renderRustDemo(usingRichTextId richTextId: Int) {
        guard let handle = handle else {
            return
        }
        sugarloaf_render_demo_with_rich_text(handle, richTextId)
    }
}

extension SugarloafWrapper {
    private func refreshFontMetrics() {
        guard let handle = handle else { return }
        var metrics = SugarloafFontMetrics(cell_width: 0, cell_height: 0, line_height: 0)
        if sugarloaf_get_font_metrics(handle, &metrics) {
            fontMetrics = metrics
            print("[SugarloafWrapper] Font Metrics: cell=\(metrics.cell_width)x\(metrics.cell_height), line_height=\(metrics.line_height)")
        }
    }
}

/// 便捷扩展,支持链式调用
extension SugarloafWrapper {
    // clear() 现在是清空屏幕,不能用于链式调用
    // clearContent() 用于清空内容

    @discardableResult
    func line() -> SugarloafWrapper {
        newLine()
        return self
    }

    @discardableResult
    func text(_ text: String, color: (Float, Float, Float, Float) = (1.0, 1.0, 1.0, 1.0)) -> SugarloafWrapper {
        addText(text, color: color)
        return self
    }

    @discardableResult
    func build() -> SugarloafWrapper {
        buildContent()
        return self
    }
}
