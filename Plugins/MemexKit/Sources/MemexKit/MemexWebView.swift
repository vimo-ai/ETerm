//
//  MemexWebView.swift
//  MemexKit
//
//  WKWebView 封装，用于加载 memex Web UI
//

import SwiftUI
import WebKit

// MARK: - ClickableWKWebView

/// 自定义 WKWebView，确保能正确接收鼠标事件
final class ClickableWKWebView: WKWebView {
    /// 允许在非激活窗口时也能接收第一次点击
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    /// 确保可以成为第一响应者
    override var acceptsFirstResponder: Bool {
        return true
    }

    /// 确保 hit test 返回自己（而不是 nil）
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 首先检查点是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }
        // 让默认实现处理，如果返回 nil 则返回自己
        return super.hitTest(point) ?? self
    }
}

// MARK: - MemexWebView

/// 嵌入式 WebView，用于加载 memex Web UI
struct MemexWebView: NSViewRepresentable {
    let url: URL

    /// 可选的加载状态回调
    var onLoadingChange: ((Bool) -> Void)?
    var onTitleChange: ((String?) -> Void)?
    var onError: ((Error) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 允许开发者工具（右键检查）
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 允许 JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // 允许媒体自动播放（如果有视频/音频）
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = ClickableWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // 允许后退/前进手势
        webView.allowsBackForwardNavigationGestures = true

        // 自定义 User-Agent 避免某些网站的兼容性问题
        webView.customUserAgent = "ETerm/1.0 Safari/605.1.15"

        // 记录初始 URL 并加载
        context.coordinator.initialURL = url
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 只在 URL 真正变化时重新加载（比较 host 和 port，忽略路径差异）
        guard let initialURL = context.coordinator.initialURL else { return }

        // 如果 URL 的 host 或 port 变化了，才重新加载
        if url.host != initialURL.host || url.port != initialURL.port {
            context.coordinator.initialURL = url
            webView.load(URLRequest(url: url))
        }
        // 否则不做任何操作，让 WebView 自己管理导航
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MemexWebView
        var initialURL: URL?

        init(_ parent: MemexWebView) {
            self.parent = parent
        }

        // 允许所有导航请求
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            print("[MemexWebView] decidePolicyFor navigationAction: \(navigationAction.request.url?.absoluteString ?? "nil")")
            decisionHandler(.allow)
        }

        // 允许所有响应
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            print("[MemexWebView] decidePolicyFor navigationResponse: \(navigationResponse.response.url?.absoluteString ?? "nil")")
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[MemexWebView] didStartProvisionalNavigation")
            parent.onLoadingChange?(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[MemexWebView] didFinish, title: \(webView.title ?? "nil")")
            parent.onLoadingChange?(false)
            parent.onTitleChange?(webView.title)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[MemexWebView] didFail: \(error.localizedDescription)")
            parent.onLoadingChange?(false)
            parent.onError?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[MemexWebView] didFailProvisionalNavigation: \(error.localizedDescription)")
            parent.onLoadingChange?(false)
            parent.onError?(error)
        }
    }
}

// MARK: - MemexWebContainer

/// 带状态管理的 WebView 容器
struct MemexWebContainer: View {
    let port: UInt16

    @State private var isLoading = true
    @State private var error: Error?
    @State private var pageTitle: String?

    /// Web UI 的 URL（memex 服务需要 serve 前端）
    private var webURL: URL {
        // 开发模式：假设 Web UI 运行在 5173 端口
        // 生产模式：memex 服务本身 serve 前端
        URL(string: "http://localhost:\(port)")!
    }

    var body: some View {
        ZStack {
            // WebView
            MemexWebView(
                url: webURL,
                onLoadingChange: { isLoading = $0 },
                onTitleChange: { pageTitle = $0 },
                onError: { error = $0 }
            )

            // 加载指示器
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading Memex...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }

            // 错误状态
            if let error = error, !isLoading {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("无法加载 Web UI")
                        .font(.headline)

                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("重试") {
                        self.error = nil
                        self.isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MemexWebContainer(port: 10013)
        .frame(width: 800, height: 600)
}
