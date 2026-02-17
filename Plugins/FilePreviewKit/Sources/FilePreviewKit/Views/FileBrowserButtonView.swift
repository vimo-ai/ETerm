//
//  FileBrowserButtonView.swift
//  FilePreviewKit
//
//  PageBar 上的文件浏览器按钮

import SwiftUI
import ETermKit

struct FileBrowserButtonView: View {
    var body: some View {
        Button(action: {
            logInfo("[FilePreviewKit] button action fired")
            FileBrowserService.shared.openFileBrowser()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text("文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}
