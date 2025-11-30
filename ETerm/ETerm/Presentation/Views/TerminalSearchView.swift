//
//  TerminalSearchView.swift
//  ETerm
//
//  终端搜索框
//

import SwiftUI

struct TerminalSearchView: View {
    @Binding var searchText: String
    @Binding var isVisible: Bool
    let matchCount: Int
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // 搜索图标
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            // 搜索输入框
            TextField("搜索...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .frame(width: 200)

            // 匹配数量
            if !searchText.isEmpty {
                Text("\(matchCount) 个匹配")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // 关闭按钮
            Button(action: {
                onClose()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .onAppear {
            // 显示时自动聚焦
            isFocused = true
        }
        .onChange(of: isVisible) {
            if isVisible {
                isFocused = true
            }
        }
    }
}

#Preview {
    VStack {
        TerminalSearchView(
            searchText: .constant("error"),
            isVisible: .constant(true),
            matchCount: 5,
            onClose: {}
        )
        .padding()
    }
    .frame(width: 400, height: 200)
}
