// EmptyProjectsView.swift
// DevHelperKit
//
// 空状态视图

import SwiftUI

/// 空状态视图
struct EmptyProjectsView: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: isScanning ? "magnifyingglass" : "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text(isScanning ? "正在扫描..." : "暂无项目")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("请先在「工作区」中添加文件夹")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
