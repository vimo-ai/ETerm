//
//  FileBrowserView.swift
//  FilePreviewKit
//
//  文件浏览器视图 — 纯 AppKit 实现
//  - 导航栏: NSButton（避免 SwiftUI 在 View Tab 中的 hit-testing 问题）
//  - 文件树: NSOutlineView（AppKit 原生事件链）

import SwiftUI
import AppKit
import Quartz

// MARK: - FileNode 模型

final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var isLoaded: Bool { children != nil }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        super.init()
    }
}

// MARK: - OutlineViewDataSource

final class FileOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var rootNodes: [FileNode] = []
    var showHiddenFiles: Bool = false
    var onDoubleClick: ((FileNode) -> Void)?
    var onSelectionChange: ((FileNode?) -> Void)?
    var onSingleClickFile: ((FileNode) -> Void)?

    private let fileManager = FileManager.default

    func loadDirectory(_ path: String) {
        rootNodes = loadChildren(at: URL(fileURLWithPath: path))
    }

    func loadChildren(of node: FileNode) {
        guard node.isDirectory, !node.isLoaded else { return }
        node.children = loadChildren(at: node.url)
    }

    private func loadChildren(at url: URL) -> [FileNode] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .map { FileNode(url: $0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootNodes.count }
        guard let node = item as? FileNode else { return 0 }
        loadChildren(of: node)
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootNodes[index] }
        return (item as! FileNode).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
            ?? makeCellView(identifier: cellId)

        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell.imageView?.image?.size = NSSize(width: 18, height: 18)

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        26
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let row = outlineView.selectedRow
        let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
        onSelectionChange?(node)
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .init(white: 0.9, alpha: 1.0)
        cell.addSubview(textField)
        cell.textField = textField

        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

// MARK: - ClickableOutlineView

final class ClickableOutlineView: NSOutlineView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Double Click

extension FileOutlineDataSource {
    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? FileNode else { return }
        onDoubleClick?(node)
    }
}

// MARK: - Quick Look

final class QLCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewURL: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as? NSURL
    }

    func showPreview(for url: URL) {
        previewURL = url
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            if panel.isVisible { panel.reloadData() }
            else { panel.makeKeyAndOrderFront(nil) }
        }
    }
}

// MARK: - FileBrowserContainerView (纯 AppKit: 导航栏 + NSOutlineView)

/// 纯 AppKit 容器，包含导航栏（NSButton）和文件树（NSOutlineView）
/// 所有交互控件都走 AppKit 原生事件链，在 View Tab 中可正常点击
final class FileBrowserContainerView: NSView {
    private let dataSource = FileOutlineDataSource()
    private let qlCoordinator = QLCoordinator()

    private var currentPath: String
    private var showHiddenFiles = false

    // 导航栏控件
    private let backButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let hiddenFilesButton = NSButton()
    private let refreshButton = NSButton()
    private let toolbarView = NSView()
    private let separatorView = NSBox()

    // 文件树
    private let scrollView = NSScrollView()
    private let outlineView = ClickableOutlineView()

    init(rootPath: String) {
        self.currentPath = rootPath
        super.init(frame: .zero)
        setupUI()
        loadCurrentDirectory()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 构建

    private func setupUI() {
        // --- 自身及导航栏深色背景 ---
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor

        // --- 导航栏 ---
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.black.cgColor
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)

        // 返回按钮
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(navigateUp)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(backButton)

        // 路径标签
        pathLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        pathLabel.textColor = .init(white: 0.85, alpha: 1.0)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(pathLabel)

        // 隐藏文件切换按钮
        hiddenFilesButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏文件")
        hiddenFilesButton.bezelStyle = .accessoryBarAction
        hiddenFilesButton.isBordered = false
        hiddenFilesButton.target = self
        hiddenFilesButton.action = #selector(toggleHiddenFiles)
        hiddenFilesButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(hiddenFilesButton)

        // 刷新按钮
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(refreshButton)

        // --- 分隔线 ---
        separatorView.boxType = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        // --- 文件树 ---
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.allowsMultipleSelection = false
        outlineView.style = .sourceList
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .black

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        dataSource.onDoubleClick = { [weak self] node in
            guard let self else { return }
            if node.isDirectory {
                self.currentPath = node.url.path
                self.loadCurrentDirectory()
            } else {
                // 可预览文件 → ETerm 内预览 tab；其他 → 系统默认应用
                let fileType = PreviewFileType.detect(url: node.url)
                if fileType != .unsupported {
                    Task { @MainActor in
                        FileBrowserService.shared.openPreview(url: node.url)
                    }
                } else {
                    NSWorkspace.shared.open(node.url)
                }
            }
        }

        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource
        outlineView.target = dataSource
        outlineView.doubleAction = #selector(FileOutlineDataSource.handleDoubleClick(_:))

        scrollView.documentView = outlineView

        // --- 约束 ---
        NSLayoutConstraint.activate([
            // 导航栏
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 36),

            backButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),

            pathLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),

            hiddenFilesButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            hiddenFilesButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            hiddenFilesButton.widthAnchor.constraint(equalToConstant: 24),

            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: hiddenFilesButton.leadingAnchor, constant: -4),

            // 分隔线
            separatorView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 文件树
            scrollView.topAnchor.constraint(equalTo: separatorView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - 数据加载

    private func loadCurrentDirectory() {
        dataSource.showHiddenFiles = showHiddenFiles
        dataSource.loadDirectory(currentPath)
        outlineView.reloadData()
        updateToolbarState()
    }

    private func updateToolbarState() {
        let dirName = URL(fileURLWithPath: currentPath).lastPathComponent
        pathLabel.stringValue = dirName.isEmpty ? "/" : dirName
        backButton.isEnabled = currentPath != "/"
        let iconName = showHiddenFiles ? "eye" : "eye.slash"
        hiddenFilesButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "隐藏文件")
    }

    // MARK: - Actions

    @objc private func navigateUp() {
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        currentPath = parent
        loadCurrentDirectory()
    }

    @objc private func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        loadCurrentDirectory()
    }

    @objc private func refresh() {
        loadCurrentDirectory()
    }
}

// MARK: - FileBrowserView (SwiftUI 包装)

struct FileBrowserView: NSViewRepresentable {
    let rootPath: String

    func makeNSView(context: Context) -> FileBrowserContainerView {
        FileBrowserContainerView(rootPath: rootPath)
    }

    func updateNSView(_ nsView: FileBrowserContainerView, context: Context) {
        // rootPath 不会变化，无需更新
    }
}
