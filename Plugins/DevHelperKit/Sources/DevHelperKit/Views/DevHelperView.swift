// DevHelperView.swift
// DevHelperKit
//
// 开发助手主视图

import SwiftUI

/// 开发助手主视图
public struct DevHelperView: View {
    @StateObject private var viewModel = DevHelperViewModel()
    @State private var selectedScript: SelectedScript?

    public init() {}

    public var body: some View {
        DevHelperContentView(
            viewModel: viewModel,
            selectedScript: $selectedScript
        )
    }
}

/// 开发助手内容视图
struct DevHelperContentView: View {
    @ObservedObject var viewModel: DevHelperViewModel
    @Binding var selectedScript: SelectedScript?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部安全区域（PageBar）
            Color.clear.frame(height: 52)

            HSplitView {
                // 左侧：项目列表
                ProjectListView(
                    viewModel: viewModel,
                    selectedScript: $selectedScript,
                    onRefresh: {
                        // 通过 IPC 请求刷新
                        NotificationCenter.default.post(
                            name: NSNotification.Name("DevHelperRefresh"),
                            object: nil
                        )
                    }
                )
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

                // 右侧：终端
                TerminalPanelView(
                    viewModel: viewModel,
                    selectedScript: $selectedScript
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
