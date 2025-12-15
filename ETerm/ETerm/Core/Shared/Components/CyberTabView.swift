/**
 * 赛博风格标签组件
 * 简约、科技感的 Tab 样式
 *
 * 设计特点：
 * - 斜切角设计（左下、右上）
 * - 细边框 + 发光效果
 * - 霓虹色调（青色/品红）
 * - 激活时有微妙的扫描线动画
 */
import SwiftUI
import AppKit

// MARK: - 赛博配色
enum CyberColor {
    /// 主色调 - 青色
    static let cyan = Color(hex: "00F0FF")
    /// 辅助色 - 品红
    static let magenta = Color(hex: "FF00FF")
    /// 警告色 - 橙色
    static let warning = Color(hex: "FF6B00")
    /// 背景色
    static let background = Color(hex: "0A0A0F")
    /// 边框色（未激活）
    static let border = Color(hex: "2A2A3A")
    /// 文字色
    static let text = Color(hex: "E0E0E0")
    /// 暗淡文字
    static let textDim = Color(hex: "6A6A7A")
}

// MARK: - 赛博 Tab 视图
struct CyberTabView: View {
    let text: String
    let isActive: Bool
    let needsAttention: Bool
    let height: CGFloat
    let onClose: (() -> Void)?

    @State private var isHovered: Bool = false

    init(_ text: String, isActive: Bool = false, needsAttention: Bool = false, height: CGFloat = 28, onClose: (() -> Void)? = nil) {
        self.text = text
        self.isActive = isActive
        self.needsAttention = needsAttention
        self.height = height
        self.onClose = onClose
    }

    /// 主题色
    private var accentColor: Color {
        if needsAttention {
            return CyberColor.warning
        }
        return isActive ? CyberColor.cyan : CyberColor.border
    }

    /// 文字颜色
    private var textColor: Color {
        if needsAttention || isActive {
            return CyberColor.text
        }
        return CyberColor.textDim
    }

    /// 斜切角大小
    private var cutSize: CGFloat { height * 0.25 }

    /// 内容宽度计算
    private var contentWidth: CGFloat {
        let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: height * 0.4)]).width
        let closeButtonWidth: CGFloat = onClose != nil ? (height * 0.35 + 8) : 0
        return textWidth + closeButtonWidth + 24
    }

    var body: some View {
        ZStack {
            // 背景
            CyberTabShape(cutSize: cutSize)
                .fill(isActive || isHovered ? accentColor.opacity(0.1) : Color.clear)

            // 边框
            CyberTabShape(cutSize: cutSize)
                .stroke(accentColor, lineWidth: isActive ? 1.5 : 1)

            // 激活时的发光效果
            if isActive || needsAttention {
                CyberTabShape(cutSize: cutSize)
                    .stroke(accentColor.opacity(0.5), lineWidth: 2)
                    .blur(radius: 3)
            }

            // 内容
            HStack(spacing: 6) {
                // 激活指示器
                if isActive {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 4, height: 4)
                        .shadow(color: accentColor, radius: 2)
                }

                Text(text)
                    .font(.system(size: height * 0.4, weight: isActive ? .medium : .regular, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                if let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: height * 0.3, weight: .medium))
                            .foregroundColor(isHovered ? CyberColor.text : CyberColor.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(width: contentWidth, height: height)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 斜切角形状
struct CyberTabShape: Shape {
    let cutSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 左下和右上斜切
        path.move(to: CGPoint(x: cutSize, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: cutSize))
        path.addLine(to: CGPoint(x: rect.maxX - cutSize, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - cutSize))
        path.closeSubpath()

        return path
    }
}

// MARK: - 赛博 Tag 视图（无关闭按钮版本）
struct CyberTagView: View {
    let text: String
    let type: CyberTagType
    let height: CGFloat

    @State private var isHovered: Bool = false

    enum CyberTagType {
        case `default`
        case primary
        case success
        case warning
        case error

        var color: Color {
            switch self {
            case .default: return CyberColor.border
            case .primary: return CyberColor.cyan
            case .success: return Color(hex: "00FF88")
            case .warning: return CyberColor.warning
            case .error: return Color(hex: "FF3366")
            }
        }
    }

    init(_ text: String, type: CyberTagType = .default, height: CGFloat = 24) {
        self.text = text
        self.type = type
        self.height = height
    }

    private var cutSize: CGFloat { height * 0.2 }

    private var contentWidth: CGFloat {
        let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: height * 0.45)]).width
        return textWidth + 20
    }

    var body: some View {
        ZStack {
            CyberTabShape(cutSize: cutSize)
                .fill(type.color.opacity(0.15))

            CyberTabShape(cutSize: cutSize)
                .stroke(type.color, lineWidth: 1)

            Text(text)
                .font(.system(size: height * 0.45, weight: .medium, design: .monospaced))
                .foregroundColor(type.color)
        }
        .frame(width: contentWidth, height: height)
    }
}

// MARK: - Preview
#Preview("Cyber Tab States") {
    VStack(spacing: 16) {
        HStack(spacing: 8) {
            CyberTabView("Terminal 1", isActive: true, height: 26) { }
            CyberTabView("Terminal 2", isActive: false, height: 26) { }
            CyberTabView("Claude", isActive: false, needsAttention: true, height: 26) { }
        }

        HStack(spacing: 8) {
            CyberTabView("Page 1", isActive: true, height: 22, onClose: nil)
            CyberTabView("Page 2", isActive: false, height: 22, onClose: nil)
            CyberTabView("Settings", isActive: false, height: 22) { }
        }
    }
    .padding(40)
    .background(CyberColor.background)
}

#Preview("Cyber Tag Types") {
    VStack(spacing: 12) {
        CyberTagView("DEFAULT")
        CyberTagView("PRIMARY", type: .primary)
        CyberTagView("SUCCESS", type: .success)
        CyberTagView("WARNING", type: .warning)
        CyberTagView("ERROR", type: .error)
    }
    .padding(40)
    .background(CyberColor.background)
}

#Preview("Cyber Tab Sizes") {
    VStack(spacing: 12) {
        CyberTabView("Small", isActive: true, height: 20) { }
        CyberTabView("Medium", isActive: true, height: 28) { }
        CyberTabView("Large", isActive: true, height: 36) { }
    }
    .padding(40)
    .background(CyberColor.background)
}
