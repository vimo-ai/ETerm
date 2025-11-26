/**
 * 水墨标签组件 - Swift 版本
 * 移植自 shuimo-ui 的 MTag 组件
 */
import SwiftUI
import AppKit

// MARK: - 标签类型
enum ShuimoTagType {
    case `default`
    case primary
    case error
    case confirm
    case warning

    var color: Color {
        switch self {
        case .default:
            return Color(nsColor: NSColor.darkGray)
        case .primary:
            return Color.blue
        case .error:
            return Color.red
        case .confirm:
            return Color.green
        case .warning:
            return Color.orange
        }
    }
}

// MARK: - SVG 资源加载工具
private enum ShuimoTagResources {
    static func loadSVG(named name: String) -> NSImage? {
        // 直接从根目录加载（Xcode 扁平化资源）
        if let url = Bundle.main.url(forResource: name, withExtension: "svg") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

// MARK: - 主视图
struct ShuimoTagView: View {
    let text: String
    let type: ShuimoTagType
    let height: CGFloat

    init(_ text: String, type: ShuimoTagType = .default, height: CGFloat = 28) {
        self.text = text
        self.type = type
        self.height = height
    }

    private var leftWidth: CGFloat { height * 51.59 / 240.61 }
    private var rightWidth: CGFloat { height * 51.72 / 240.58 }
    private var mainTileWidth: CGFloat { height * 342.19 / 241.76 }

    private var contentWidth: CGFloat {
        let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: height * 0.45)]).width
        return textWidth + 16
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                tagBorder(name: "left", width: leftWidth)
                tagMain()
                tagBorder(name: "right", width: rightWidth)
            }

            Text(text)
                .font(.system(size: height * 0.45))
                .foregroundColor(.white)
                .padding(.leading, leftWidth + 8)
                .padding(.trailing, rightWidth + 8)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func tagBorder(name: String, width: CGFloat) -> some View {
        if let svgImage = ShuimoTagResources.loadSVG(named: name) {
            Rectangle()
                .fill(type.color)
                .frame(width: width, height: height)
                .mask(
                    Image(nsImage: svgImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
        } else {
            Rectangle()
                .fill(type.color)
                .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func tagMain() -> some View {
        let tileCount = Int(ceil(contentWidth / mainTileWidth)) + 1

        if let svgImage = ShuimoTagResources.loadSVG(named: "main") {
            Rectangle()
                .fill(type.color)
                .frame(width: contentWidth, height: height)
                .mask(
                    HStack(spacing: 0) {
                        ForEach(0..<tileCount, id: \.self) { _ in
                            Image(nsImage: svgImage)
                                .resizable()
                                .frame(width: mainTileWidth, height: height)
                        }
                    }
                )
        } else {
            Rectangle()
                .fill(type.color)
                .frame(width: contentWidth, height: height)
        }
    }
}

// MARK: - Tab 专用视图（带关闭按钮）
struct ShuimoTabView: View {
    let text: String
    let isActive: Bool
    let height: CGFloat
    let onClose: (() -> Void)?

    init(_ text: String, isActive: Bool = false, height: CGFloat = 28, onClose: (() -> Void)? = nil) {
        self.text = text
        self.isActive = isActive
        self.height = height
        self.onClose = onClose
    }

    private var tagColor: Color {
        isActive ? Color.black.opacity(0.8) : Color.gray.opacity(0.6)
    }

    private var leftWidth: CGFloat { height * 51.59 / 240.61 }
    private var rightWidth: CGFloat { height * 51.72 / 240.58 }
    private var mainTileWidth: CGFloat { height * 342.19 / 241.76 }

    private var contentWidth: CGFloat {
        let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: height * 0.4)]).width
        let closeButtonWidth: CGFloat = onClose != nil ? (height * 0.3 + 4) : 0
        return textWidth + closeButtonWidth + 16
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                tagBorder(name: "left", width: leftWidth)
                tagMain()
                tagBorder(name: "right", width: rightWidth)
            }

            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: height * 0.4))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: height * 0.3))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, leftWidth + 8)
            .padding(.trailing, rightWidth + 8)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func tagBorder(name: String, width: CGFloat) -> some View {
        if let svgImage = ShuimoTagResources.loadSVG(named: name) {
            Rectangle()
                .fill(tagColor)
                .frame(width: width, height: height)
                .mask(
                    Image(nsImage: svgImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
        } else {
            Rectangle()
                .fill(tagColor)
                .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func tagMain() -> some View {
        let tileCount = Int(ceil(contentWidth / mainTileWidth)) + 1

        if let svgImage = ShuimoTagResources.loadSVG(named: "main") {
            Rectangle()
                .fill(tagColor)
                .frame(width: contentWidth, height: height)
                .mask(
                    HStack(spacing: 0) {
                        ForEach(0..<tileCount, id: \.self) { _ in
                            Image(nsImage: svgImage)
                                .resizable()
                                .frame(width: mainTileWidth, height: height)
                        }
                    }
                )
        } else {
            Rectangle()
                .fill(tagColor)
                .frame(width: contentWidth, height: height)
        }
    }
}

// MARK: - Preview
#Preview("Tab States") {
    VStack(spacing: 16) {
        ShuimoTabView("终端 1", isActive: true) { print("close") }
        ShuimoTabView("终端 2", isActive: false) { print("close") }
        ShuimoTabView("很长的标签名称", isActive: true) { print("close") }
    }
    .padding(40)
    .background(Color.black.opacity(0.8))
}

#Preview("Tag Types") {
    VStack(spacing: 16) {
        ShuimoTagView("默认标签")
        ShuimoTagView("主要", type: .primary)
        ShuimoTagView("错误", type: .error)
        ShuimoTagView("成功", type: .confirm)
        ShuimoTagView("警告", type: .warning)
    }
    .padding(40)
    .background(Color.white)
}

#Preview("Tag Sizes") {
    VStack(spacing: 16) {
        ShuimoTagView("小标签", height: 20)
        ShuimoTagView("中标签", height: 28)
        ShuimoTagView("大标签", height: 200)
    }
    .padding(40)
    .background(Color.white)
}
