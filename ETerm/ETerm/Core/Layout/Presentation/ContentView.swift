//
//  ContentView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI
import Combine
import AppKit
import SwiftData

// MARK: - Window CWD Manager

/// 临时存储新窗口的 CWD（用于窗口创建时传递）
class WindowCwdManager {
    static let shared = WindowCwdManager()

    private var pendingCwd: String?
    private let lock = NSLock()

    private init() {}

    /// 设置下一个待创建窗口的 CWD
    func setPendingCwd(_ cwd: String?) {
        lock.lock()
        defer { lock.unlock() }
        pendingCwd = cwd
    }

    /// 获取并清除待创建窗口的 CWD
    func takePendingCwd() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let cwd = pendingCwd
        pendingCwd = nil
        return cwd
    }
}

struct ContentView: View {
    /// Coordinator 由 WindowManager 创建和管理，不使用 @StateObject
    @ObservedObject var coordinator: TerminalWindowCoordinator

    // 侧边栏状态
    @State private var showSidebar = false
    @State private var selectedSidebarItem: SidebarItemType? = nil  // 默认不选中任何项
    @ObservedObject var sidebarRegistry = SidebarRegistry.shared

    var body: some View {
        // 读取 updateTrigger 强制刷新
        let _ = coordinator.updateTrigger

        ZStack(alignment: .topLeading) {
            // 终端视图始终存在，只是根据 Page 类型隐藏/显示
            let isPluginPage = coordinator.terminalWindow.active.page?.isPluginPage ?? false

            // 终端视图（插件页面时隐藏，但不销毁）
            RioTerminalView(coordinator: coordinator)
                .frame(minWidth: 400, minHeight: 300)
                .opacity(isPluginPage ? 0 : 1)
                .allowsHitTesting(!isPluginPage)

            // View Tab 覆盖层：在 SwiftUI 层直接渲染插件视图（绕过 AppKit NSHostingView 桥接）
            if !isPluginPage && !coordinator.viewTabOverlays.isEmpty {
                viewTabOverlayLayer
            }

            // 插件页面视图（终端页面时隐藏）
            if let activePage = coordinator.terminalWindow.active.page, isPluginPage {
                pluginPageContent(for: activePage)
                    .frame(minWidth: 400, minHeight: 300)
            }

            // PageBar 在顶部（覆盖在终端上方，与红绿灯同一行）
            // 直接放置，不用 VStack+Spacer 包裹，避免全屏覆盖层干扰底层 AppKit hit-testing chain
            AppKitPageBar(coordinator: coordinator)
                .frame(height: PageBarHostingView.recommendedHeight())

            // 侧边栏背景遮罩：点击关闭侧边栏（放在详情面板和侧边栏下面）
            if showSidebar {
                Color.black.opacity(0.01)  // 几乎透明但可点击
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSidebar = false
                            selectedSidebarItem = nil
                        }
                    }
            }

            // 侧边栏选中项的详情视图
            if showSidebar, let item = selectedSidebarItem {
                sidebarDetailView(for: item)
                    .transition(.opacity)
            }

            // 侧边栏（悬浮在左侧）
            if showSidebar {
                CustomSidebar(
                    selectedItem: $selectedSidebarItem,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSidebar = false
                            selectedSidebarItem = nil
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .ignoresSafeArea()
        .background(
            ZStack {
                TransparentWindowBackground()
                Color.black.opacity(0.9)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleSidebar"))) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showSidebar.toggle()
                if !showSidebar {
                    selectedSidebarItem = nil  // 关闭时清除选中项
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .viewTabRegistered)) { _ in
            // View Tab 视图注册后刷新 SwiftUI 层
            coordinator.updateTrigger = UUID()
        }
    }

    /// 插件页面内容视图
    @ViewBuilder
    private func pluginPageContent(for page: Page) -> some View {
        if case .plugin(_, let viewProvider) = page.content {
            viewProvider()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyView()
        }
    }

    /// View Tab 覆盖层：在 SwiftUI 层直接渲染插件视图
    ///
    /// 坐标转换：AppKit contentBounds (origin 在左下角) → SwiftUI (origin 在左上角)
    /// pageBarHeight 在顶部，contentBounds 在其下方
    @ViewBuilder
    private var viewTabOverlayLayer: some View {
        let pageBarHeight: CGFloat = PageBarHostingView.recommendedHeight()

        GeometryReader { _ in
            ForEach(coordinator.viewTabOverlays) { overlay in
                // AppKit → SwiftUI Y 轴翻转
                // AppKit contentBounds: origin 在左下角，y 向上增长
                // SwiftUI: origin 在左上角，y 向下增长
                // pageBarHeight 在 SwiftUI 顶部，contentBounds 在其下方
                let containerHeight = overlay.containerHeight
                let swiftUIX = overlay.bounds.origin.x
                let swiftUIY = pageBarHeight + (containerHeight - overlay.bounds.origin.y - overlay.bounds.height)

                Group {
                    if let view = ViewTabRegistry.shared.getView(for: overlay.viewId) {
                        view
                    } else {
                        viewTabPlaceholder(viewId: overlay.viewId)
                    }
                }
                .frame(width: overlay.bounds.width, height: overlay.bounds.height)
                .position(
                    x: swiftUIX + overlay.bounds.width / 2,
                    y: swiftUIY + overlay.bounds.height / 2
                )
            }
        }
        .allowsHitTesting(true)
    }

    /// View Tab 占位视图（插件加载中显示）
    @ViewBuilder
    private func viewTabPlaceholder(viewId: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("正在加载...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 侧边栏详情视图（居中显示，半透明圆角）
    @ViewBuilder
    private func sidebarDetailView(for item: SidebarItemType) -> some View {
        Group {
            switch item {
            #if !TEAM_BUILD
            case .builtin(.settings):
                SettingsView()
                    .frame(maxWidth: 700, maxHeight: 600)
                    .contentShape(Rectangle())  // 阻止点击穿透到背景遮罩
                    .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                    .padding(40)
                    .injectModelContainer()  // 注入 ModelContainer
            #endif

            case .builtin(.shortcuts):
                ShortcutsView()
                    .frame(maxWidth: 700, maxHeight: 600)
                    .contentShape(Rectangle())  // 阻止点击穿透到背景遮罩
                    .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                    .padding(40)

            #if !TEAM_BUILD
            case .builtin(.plugins):
                PluginManagerView()
                    .frame(maxWidth: 600, maxHeight: 500)
                    .contentShape(Rectangle())  // 阻止点击穿透到背景遮罩
                    .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                    .padding(40)
            #endif

            case .plugin(let tabId):
                // 查找插件注册的视图
                if let tab = sidebarRegistry.allTabs.first(where: { $0.id == tabId }) {
                    tab.viewProvider()
                        .frame(maxWidth: 700, maxHeight: 600)
                        .contentShape(Rectangle())  // 阻止点击穿透到背景遮罩
                        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                        .padding(40)
                        .injectModelContainer()  // 注入 ModelContainer
                } else {
                    Text("插件视图未找到")
                        .foregroundColor(.secondary)
                }

            #if TEAM_BUILD
            default:
                EmptyView()
            #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // 填充整个区域以居中
    }

    // 窗口配置已移至 KeyableWindow 和 WindowManager
}

// MARK: - SwiftData ModelContainer 注入扩展

extension View {
    /// 注入 ModelContainer 到视图环境
    func injectModelContainer() -> some View {
        self.modifier(ModelContainerModifier())
    }
}

struct ModelContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let modelContainer = appDelegate.modelContainer {
            content.modelContainer(modelContainer)
        } else {
            content
        }
    }
}

// MARK: - Translation Manager

/// 翻译管理器（单例）
class TranslationManager: ObservableObject {
    static let shared = TranslationManager()

    @Published var selectedText: String?
    var onDismiss: (() -> Void)?

    private init() {}

    func showTranslation(for text: String) {
        guard !text.isEmpty else { return }
        selectedText = text
    }

    func dismissPopover() {
        selectedText = nil
        onDismiss?()
    }
}

// 半透明窗口背景
struct TransparentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow  // 可选: .hudWindow, .popover, .sidebar, .menu, .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    // Preview 需要创建一个临时的 Coordinator
    let registry = TerminalWorkingDirectoryRegistry()
    let initialTab = TerminalWindow.makeDefaultTab()
    let initialPanel = EditorPanel(initialTab: initialTab)
    let terminalWindow = TerminalWindow(initialPanel: initialPanel)
    let coordinator = TerminalWindowCoordinator(
        initialWindow: terminalWindow,
        workingDirectoryRegistry: registry
    )
    ContentView(coordinator: coordinator)
}
