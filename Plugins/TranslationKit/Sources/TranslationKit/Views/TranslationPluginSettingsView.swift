//
//  TranslationPluginSettingsView.swift
//  TranslationKit
//
//  翻译插件配置视图
//

import SwiftUI

// MARK: - Settings Section View

private struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            content()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Main View

struct TranslationPluginSettingsView: View {
    @StateObject private var configManager = TranslationPluginConfigManager.shared

    @State private var dispatcherModel: String = ""
    @State private var analysisModel: String = ""
    @State private var translationModel: String = ""
    @State private var showSaveResult = false
    @State private var saveSuccess = false
    @State private var saveMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("翻译插件配置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            // 配置内容
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSectionView(title: "模型配置") {
                        VStack(alignment: .leading, spacing: 16) {
                            // 说明文字
                            Text("配置翻译插件使用的 AI 模型")
                                .font(.callout)
                                .foregroundColor(.secondary)

                            // 三个模型字段
                            VStack(alignment: .leading, spacing: 12) {
                                ModelConfigField(
                                    label: "调度模型",
                                    model: $dispatcherModel,
                                    placeholder: "qwen-flash",
                                    description: "用于判断文本需要的分析类型"
                                )

                                ModelConfigField(
                                    label: "分析模型",
                                    model: $analysisModel,
                                    placeholder: "qwen3-max",
                                    description: "用于深度语法和语义分析"
                                )

                                ModelConfigField(
                                    label: "翻译模型",
                                    model: $translationModel,
                                    placeholder: "qwen-mt-flash",
                                    description: "用于文本翻译"
                                )
                            }

                            Divider()

                            // 操作按钮
                            HStack(spacing: 12) {
                                Button("重置为默认", action: resetToDefault)
                                    .foregroundColor(.orange)

                                Spacer()

                                Button("保存", action: saveConfig)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!isFormValid)
                            }

                            // 保存结果提示
                            if showSaveResult {
                                HStack {
                                    Image(systemName: saveSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(saveSuccess ? .green : .red)
                                    Text(saveMessage)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(saveSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                )
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear(perform: loadConfig)
    }

    // MARK: - Helper Properties

    private var isFormValid: Bool {
        !dispatcherModel.isEmpty && !analysisModel.isEmpty && !translationModel.isEmpty
    }

    // MARK: - Methods

    private func loadConfig() {
        let config = configManager.config
        dispatcherModel = config.dispatcherModel
        analysisModel = config.analysisModel
        translationModel = config.translationModel
    }

    private func saveConfig() {
        configManager.config = TranslationPluginConfig(
            dispatcherModel: dispatcherModel,
            analysisModel: analysisModel,
            translationModel: translationModel
        )

        saveSuccess = true
        saveMessage = "配置已保存"
        showSaveResult = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showSaveResult = false
        }
    }

    private func resetToDefault() {
        let defaultConfig = TranslationPluginConfig.default
        dispatcherModel = defaultConfig.dispatcherModel
        analysisModel = defaultConfig.analysisModel
        translationModel = defaultConfig.translationModel
    }
}

// MARK: - Model Config Field

struct ModelConfigField: View {
    let label: String
    @Binding var model: String
    let placeholder: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(width: 80, alignment: .leading)

                TextField(placeholder, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .focusable(true)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 80)
        }
    }
}

#Preview {
    TranslationPluginSettingsView()
}
