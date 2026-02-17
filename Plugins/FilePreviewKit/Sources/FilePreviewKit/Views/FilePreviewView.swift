//
//  FilePreviewView.swift
//  FilePreviewKit
//
//  通用文件预览容器 — 标题栏 + 内容区域
//  支持 Markdown 渲染和代码文本显示

import SwiftUI
import AppKit

// MARK: - 文件类型判断

enum PreviewFileType {
    case markdown
    case code
    case text
    case unsupported

    static func detect(url: URL) -> PreviewFileType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd":
            return .markdown
        case "swift", "rs", "py", "js", "ts", "tsx", "jsx",
             "go", "java", "kt", "c", "cpp", "h", "hpp", "m",
             "rb", "php", "sh", "bash", "zsh", "fish",
             "yaml", "yml", "toml", "json", "xml", "html", "css",
             "sql", "graphql", "proto", "dockerfile",
             "r", "lua", "zig", "nim", "dart", "scala",
             "makefile", "cmake", "gradle":
            return .code
        case "txt", "log", "csv", "env", "gitignore", "editorconfig",
             "conf", "cfg", "ini", "properties":
            return .text
        default:
            // 尝试检查是否为纯文本
            if isPlainText(url: url) { return .text }
            return .unsupported
        }
    }

    /// 检查文件是否为 UTF-8 纯文本（读取前 8KB）
    private static func isPlainText(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 8192)
        return String(data: data, encoding: .utf8) != nil
    }
}

// MARK: - FilePreviewView

struct FilePreviewView: View {
    let fileURL: URL

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            titleBar
            Divider()

            // 内容区域
            contentView
        }
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        HStack(spacing: 8) {
            // 文件图标
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 16, height: 16)

            // 文件名
            Text(fileURL.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            // 路径（缩略显示）
            Text(fileURL.deletingLastPathComponent().path.abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            // 用系统应用打开
            Button(action: { NSWorkspace.shared.open(fileURL) }) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("用默认应用打开")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 内容区域

    @ViewBuilder
    private var contentView: some View {
        let fileType = PreviewFileType.detect(url: fileURL)
        switch fileType {
        case .markdown:
            MarkdownPreviewView(fileURL: fileURL)
        case .code, .text:
            CodePreviewView(fileURL: fileURL)
        case .unsupported:
            unsupportedView
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("无法预览此文件类型")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Button("用默认应用打开") {
                NSWorkspace.shared.open(fileURL)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 代码/文本预览

private struct CodePreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        // 不自动换行
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            textView.string = content
        } else {
            textView.string = "// 无法读取文件内容"
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - String 扩展

private extension String {
    var abbreviatingWithTildeInPath: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
