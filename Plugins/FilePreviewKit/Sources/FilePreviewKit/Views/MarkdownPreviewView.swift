//
//  MarkdownPreviewView.swift
//  FilePreviewKit
//
//  Markdown 渲染视图 — WKWebView + Swift Markdown→HTML 转换

import SwiftUI
import WebKit

// MARK: - Markdown → HTML 转换

enum MarkdownRenderer {
    /// 将 Markdown 文本转换为 HTML 字符串
    static func renderToHTML(_ markdown: String) -> String {
        var html = escapeHTML(markdown)

        // 代码块（fenced code blocks）— 必须在行内代码之前处理
        html = replacePattern(
            html,
            pattern: "```(\\w*)\\n([\\s\\S]*?)```",
            template: "<pre><code class=\"language-$1\">$2</code></pre>"
        )

        // 行内代码
        html = replacePattern(html, pattern: "`([^`]+)`", template: "<code>$1</code>")

        // 标题 (h1-h6)
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level)
            html = replacePattern(
                html,
                pattern: "(?m)^\(prefix)\\s+(.+)$",
                template: "<h\(level)>$1</h\(level)>"
            )
        }

        // 粗体 + 斜体
        html = replacePattern(html, pattern: "\\*\\*\\*(.+?)\\*\\*\\*", template: "<strong><em>$1</em></strong>")
        html = replacePattern(html, pattern: "\\*\\*(.+?)\\*\\*", template: "<strong>$1</strong>")
        html = replacePattern(html, pattern: "\\*(.+?)\\*", template: "<em>$1</em>")

        // 链接
        html = replacePattern(html, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", template: "<a href=\"$2\">$1</a>")

        // 图片
        html = replacePattern(html, pattern: "!\\[([^\\]]*?)\\]\\(([^)]+)\\)", template: "<img src=\"$2\" alt=\"$1\" />")

        // 水平线
        html = replacePattern(html, pattern: "(?m)^---+$", template: "<hr />")

        // 无序列表项
        html = replacePattern(html, pattern: "(?m)^[\\*\\-]\\s+(.+)$", template: "<li>$1</li>")

        // 有序列表项
        html = replacePattern(html, pattern: "(?m)^\\d+\\.\\s+(.+)$", template: "<li>$1</li>")

        // 引用块
        html = replacePattern(html, pattern: "(?m)^>\\s+(.+)$", template: "<blockquote>$1</blockquote>")

        // 合并连续 blockquote
        html = html.replacingOccurrences(of: "</blockquote>\n<blockquote>", with: "\n")

        // 段落：连续非标签行包裹 <p>
        html = wrapParagraphs(html)

        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replacePattern(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func wrapParagraphs(_ html: String) -> String {
        let blockTags = ["<h", "<pre", "<blockquote", "<hr", "<li", "<ul", "<ol"]
        var result: [String] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                let text = paragraphLines.joined(separator: "<br />")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append("<p>\(text)</p>")
                }
                paragraphLines.removeAll()
            }
        }

        for line in html.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
            } else if blockTags.contains(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                result.append(line)
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()

        return result.joined(separator: "\n")
    }
}

// MARK: - HTML 模板

enum HTMLTemplate {
    static func wrap(body: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root {
            --bg: #000000;
            --fg: #f5f5f7;
            --fg-secondary: #86868b;
            --border: #424245;
            --code-bg: #2c2c2e;
            --link: #2997ff;
            --blockquote-border: #424245;
            --blockquote-bg: #2c2c2e;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: var(--fg);
            background: var(--bg);
            padding: 24px 32px;
            max-width: 800px;
            margin: 0 auto;
            -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 1.5em;
            margin-bottom: 0.5em;
            font-weight: 600;
            line-height: 1.3;
        }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.4em; }
        h3 { font-size: 1.2em; }
        h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
        p { margin-bottom: 1em; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: "SF Mono", Menlo, Monaco, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 2px 6px;
            border-radius: 4px;
        }
        pre {
            background: var(--code-bg);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            margin: 1em 0;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 13px;
            line-height: 1.5;
        }
        blockquote {
            border-left: 3px solid var(--blockquote-border);
            background: var(--blockquote-bg);
            padding: 12px 16px;
            margin: 1em 0;
            border-radius: 0 6px 6px 0;
            color: var(--fg-secondary);
        }
        hr {
            border: none;
            border-top: 1px solid var(--border);
            margin: 2em 0;
        }
        li {
            margin-left: 1.5em;
            margin-bottom: 0.3em;
        }
        img {
            max-width: 100%;
            border-radius: 8px;
            margin: 1em 0;
        }
        strong { font-weight: 600; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

// MARK: - ClickableWKWebView

private final class ClickableWKWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - MarkdownPreviewView

struct MarkdownPreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = ClickableWKWebView(frame: .zero, configuration: config)
        webView.wantsLayer = true
        webView.navigationDelegate = context.coordinator

        // 固定深色背景，避免加载前白色闪烁
        webView.setValue(true, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.black.cgColor

        loadMarkdown(into: webView)
        context.coordinator.startWatching(fileURL: fileURL, webView: webView, loader: loadMarkdown)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadMarkdown(into webView: WKWebView) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let htmlBody = MarkdownRenderer.renderToHTML(content)
        let fullHTML = HTMLTemplate.wrap(body: htmlBody, title: fileURL.lastPathComponent)
        webView.loadHTMLString(fullHTML, baseURL: fileURL.deletingLastPathComponent())
    }

    // MARK: - Coordinator（导航代理 + 文件监听）

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var fileSource: DispatchSourceFileSystemObject?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 拦截链接点击，用系统浏览器打开
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func startWatching(fileURL: URL, webView: WKWebView,
                           loader: @escaping (WKWebView) -> Void) {
            stopWatching()
            let fd = open(fileURL.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename],
                queue: .main
            )
            source.setEventHandler { [weak webView] in
                guard let webView else { return }
                loader(webView)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileSource = source
        }

        func stopWatching() {
            fileSource?.cancel()
            fileSource = nil
        }

        deinit { stopWatching() }
    }
}
