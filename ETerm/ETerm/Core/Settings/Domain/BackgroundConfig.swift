//
//  BackgroundConfig.swift
//  ETerm
//
//  终端背景配置 - 支持山水画/自定义图片/无背景

import Foundation
import AppKit
import Combine

/// 背景模式
enum BackgroundMode: String, CaseIterable {
    case mountain = "mountain"  // 默认山水画
    case custom = "custom"      // 自定义图片
    case plain = "plain"        // 无背景

    var displayName: String {
        switch self {
        case .mountain: return "山水画"
        case .custom: return "自定义图片"
        case .plain: return "无背景"
        }
    }
}

/// 背景配置管理器
///
/// 使用 Combine sink 替代 @Published + didSet，
/// 避免 SwiftUI 已知的 didSet 不触发问题。
final class BackgroundConfig: ObservableObject {
    static let shared = BackgroundConfig()

    private let defaults = UserDefaults.standard
    private let modeKey = "background.mode"
    private let imagePathKey = "background.customImagePath"
    private let opacityKey = "background.opacity"
    private var cancellables = Set<AnyCancellable>()

    @Published var mode: BackgroundMode
    @Published var customImagePath: String?
    @Published var opacity: Double

    private init() {
        let savedMode = defaults.string(forKey: modeKey) ?? BackgroundMode.mountain.rawValue
        self.mode = BackgroundMode(rawValue: savedMode) ?? .mountain
        self.customImagePath = defaults.string(forKey: imagePathKey)
        self.opacity = defaults.object(forKey: opacityKey) as? Double ?? 0.5

        // dropFirst() 跳过 init 赋值产生的初始值
        $mode
            .dropFirst()
            .sink { [weak self] newMode in
                self?.defaults.set(newMode.rawValue, forKey: self?.modeKey ?? "")
            }
            .store(in: &cancellables)

        $customImagePath
            .dropFirst()
            .sink { [weak self] newPath in
                self?.defaults.set(newPath, forKey: self?.imagePathKey ?? "")
            }
            .store(in: &cancellables)

        $opacity
            .dropFirst()
            .sink { [weak self] newOpacity in
                self?.defaults.set(newOpacity, forKey: self?.opacityKey ?? "")
            }
            .store(in: &cancellables)
    }

    /// 加载自定义图片
    var customImage: NSImage? {
        guard let path = customImagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
