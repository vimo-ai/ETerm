//
//  InlineComposerView.swift
//  TranslationKit
//
//  Inline Writing Assistant - Cmd+K 快捷写作助手
//  SDK 插件版本 - 使用 HostBridge 与宿主通信
//

import SwiftUI
import AppKit
import ETermKit

// MARK: - Grammar Category Mapping

private struct GrammarCategory {
    let name: String
    let icon: String
    let color: Color

    static let mapping: [String: GrammarCategory] = [
        "tense": GrammarCategory(name: "时态错误", icon: "⏰", color: Color(red: 0x4a/255, green: 0x99/255, blue: 0x92/255)),
        "article": GrammarCategory(name: "冠词错误", icon: "📘", color: Color(red: 0x00/255, green: 0x7a/255, blue: 0xcc/255)),
        "preposition": GrammarCategory(name: "介词错误", icon: "📗", color: Color(red: 0x73/255, green: 0xc9/255, blue: 0x91/255)),
        "subject_verb_agreement": GrammarCategory(name: "主谓一致", icon: "📙", color: Color(red: 0xfc/255, green: 0xa1/255, blue: 0x04/255)),
        "word_order": GrammarCategory(name: "词序错误", icon: "🔄", color: Color(red: 0x9b/255, green: 0x59/255, blue: 0xb6/255)),
        "singular_plural": GrammarCategory(name: "单复数错误", icon: "🔢", color: Color(red: 0x3d/255, green: 0x98/255, blue: 0xd3/255)),
        "punctuation": GrammarCategory(name: "标点错误", icon: "❗️", color: Color(red: 0xe7/255, green: 0x4c/255, blue: 0x3c/255)),
        "spelling": GrammarCategory(name: "拼写错误", icon: "✏️", color: Color(red: 0xe6/255, green: 0x74/255, blue: 0x94/255)),
        "word_choice": GrammarCategory(name: "用词错误", icon: "💭", color: Color(red: 0x95/255, green: 0xa5/255, blue: 0xa6/255)),
        "sentence_structure": GrammarCategory(name: "句子结构", icon: "🏗️", color: Color(red: 0x34/255, green: 0x98/255, blue: 0xdb/255)),
        "other": GrammarCategory(name: "其他错误", icon: "📝", color: Color(red: 0x7f/255, green: 0x8c/255, blue: 0x8d/255))
    ]

    static func get(_ category: String) -> GrammarCategory {
        mapping[category] ?? GrammarCategory(name: "其他错误", icon: "📝", color: Color(red: 0x7f/255, green: 0x8c/255, blue: 0x8d/255))
    }
}

// MARK: - Data Types

enum WritingError: LocalizedError {
    case missingHost
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "HostBridge 未配置"
        case .emptyResponse:
            return "AI 返回了空响应"
        }
    }
}

private enum AnalysisTask {
    case fixes([GrammarFix])
    case idiomatic([IdiomaticSuggestion])
    case translation(String, [Translation])
    case explanation([GrammarPoint])
}

// MARK: - Theme (Shuimo-inspired)
private enum ComposerTheme {
    static let accent = Color(red: 0x4a/255, green: 0x99/255, blue: 0x92/255)
    static let success = Color(red: 0x73/255, green: 0xc9/255, blue: 0x91/255)
    static let warning = Color(red: 0xfc/255, green: 0xa1/255, blue: 0x04/255)
    static let danger = Color(red: 0xc7/255, green: 0x4e/255, blue: 0x39/255)
    static let info = Color(red: 0x00/255, green: 0x7a/255, blue: 0xcc/255)
    static let surface = Color(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255).opacity(0.95)
    static let border = Color(red: 0x09/255, green: 0x47/255, blue: 0x71/255).opacity(0.75)
    static let textSecondary = Color(red: 0x7f/255, green: 0x84/255, blue: 0x8e/255)
}

// MARK: - PreferenceKey for Input Area Height

struct ComposerInputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Custom NSTextView to handle Cmd+Enter

/// 自定义 NSTextView，重写 performKeyEquivalent 来处理 Cmd+Enter
class ComposerNSTextView: NSTextView {
    var onCmdEnter: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+Enter：换行
        if event.modifierFlags.contains(.command) && event.keyCode == 36 {
            self.insertText("\n", replacementRange: self.selectedRange())
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Custom TextEditor with Enter to Submit

/// 自定义文本编辑器：Enter 发送，Cmd+Enter 换行，Option+Enter 直接发送到 Terminal
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onOptionEnter: () -> Void
    @Binding var textHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onOptionEnter: onOptionEnter, textHeight: $textHeight)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 创建自定义 NSTextView
        let textView = ComposerNSTextView()
        textView.autoresizingMask = [.width, .height]

        // 创建 ScrollView
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)  // 移除内部 padding，使用外部统一 padding
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // 设置高度范围：最小 1 行，最大 4 行（约 20pt * 4 = 80pt）
        textView.minSize = NSSize(width: 0, height: 20)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 80)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        context.coordinator.textView = textView

        // 自动获得焦点
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onOptionEnter: () -> Void
        @Binding var textHeight: CGFloat
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onOptionEnter: @escaping () -> Void, textHeight: Binding<CGFloat>) {
            self._text = text
            self.onSubmit = onSubmit
            self.onOptionEnter = onOptionEnter
            self._textHeight = textHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string

            // 计算实际渲染高度
            updateHeight(for: textView)
        }

        private func updateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // 强制布局，确保获取正确的高度
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)

            // 计算高度：直接使用内容高度（无内部 padding）
            let contentHeight = usedRect.height

            // 限制在 20pt（1 行）到 80pt（4 行）之间
            let clampedHeight = min(max(contentHeight, 20), 80)

            // 更新绑定的高度
            DispatchQueue.main.async {
                self.textHeight = clampedHeight
            }
        }

        // 拦截键盘事件
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // 处理 Enter 键（普通 Enter 和 Cmd+Enter 可能触发不同的选择器）
            let isEnterCommand = commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                                 commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))

            if isEnterCommand {
                guard let event = NSApp.currentEvent else {
                    // 无事件，默认发送
                    onSubmit()
                    return true
                }

                // Option+Enter：直接发送到 Terminal（跳过检查）
                if event.modifierFlags.contains(.option) {
                    onOptionEnter()
                    return true
                }

                // Cmd+Enter：换行
                if event.modifierFlags.contains(.command) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }

                // Enter：发送（第一次检查，第二次发送到 Terminal）
                onSubmit()
                return true
            }

            return false  // 其他命令保持原生行为
        }
    }
}

// MARK: - Metal Shader 沿路径渐变边框
struct PolylineVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct PathGradientBorder: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    @State private var phase: CGFloat = 0

    // Shuimo-inspired teal/blue ribbon（去掉黄，只保留冷色系过渡）
    private let colors: [SIMD4<Float>] = [
        SIMD4<Float>(74.0/255.0, 153.0/255.0, 146.0/255.0, 1.0),  // teal
        SIMD4<Float>(0.0/255.0, 122.0/255.0, 204.0/255.0, 1.0),   // blue
        SIMD4<Float>(22.0/255.0, 97.0/255.0, 171.0/255.0, 1.0),   // deep blue
        SIMD4<Float>(74.0/255.0, 153.0/255.0, 146.0/255.0, 1.0),  // teal
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let currentPhase = CGFloat(time.truncatingRemainder(dividingBy: 4.0) / 4.0)

            Canvas { ctx, size in
                let vertices = generateRoundedRectVertices(
                    size: size,
                    cornerRadius: cornerRadius,
                    phase: currentPhase
                )

                guard vertices.count >= 2 else { return }

                // 构建路径
                var path = Path()
                path.move(to: CGPoint(
                    x: Double(vertices[0].position.x),
                    y: Double(vertices[0].position.y)
                ))
                for v in vertices.dropFirst() {
                    path.addLine(to: CGPoint(
                        x: Double(v.position.x),
                        y: Double(v.position.y)
                    ))
                }

                // 转换为 Data
                let data = vertices.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }

                // 使用 Metal shader
                let shaderStyle = GraphicsContext.Shading.shader(
                    ShaderLibrary.pathGradientShader(.data(data))
                )

                // 绘制主边框（锐利）
                var mainCtx = ctx
                mainCtx.opacity = 0.8
                mainCtx.stroke(
                    path,
                    with: shaderStyle,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
    }

    // 手动生成圆角矩形顶点（确保圆角正确）
    private func generateRoundedRectVertices(size: CGSize, cornerRadius: CGFloat, phase: CGFloat) -> [PolylineVertex] {
        let r = min(cornerRadius, min(size.width, size.height) / 2)
        let w = size.width
        let h = size.height

        var points: [CGPoint] = []

        // 每个圆角的采样数
        let arcSegments = 16

        // 从左上角开始，顺时针
        // 左上角圆弧 (从 180° 到 270°，即 π 到 3π/2)
        for i in 0...arcSegments {
            let angle = CGFloat.pi + CGFloat(i) / CGFloat(arcSegments) * (CGFloat.pi / 2)
            points.append(CGPoint(x: r + r * cos(angle), y: r + r * sin(angle)))
        }

        // 顶边（从左上到右上）
        points.append(CGPoint(x: w - r, y: 0))

        // 右上角圆弧 (从 270° 到 360°，即 3π/2 到 2π)
        for i in 1...arcSegments {
            let angle = CGFloat.pi * 1.5 + CGFloat(i) / CGFloat(arcSegments) * (CGFloat.pi / 2)
            points.append(CGPoint(x: w - r + r * cos(angle), y: r + r * sin(angle)))
        }

        // 右边（从右上到右下）
        points.append(CGPoint(x: w, y: h - r))

        // 右下角圆弧 (从 0° 到 90°)
        for i in 1...arcSegments {
            let angle = CGFloat(i) / CGFloat(arcSegments) * (CGFloat.pi / 2)
            points.append(CGPoint(x: w - r + r * cos(angle), y: h - r + r * sin(angle)))
        }

        // 底边（从右下到左下）
        points.append(CGPoint(x: r, y: h))

        // 左下角圆弧 (从 90° 到 180°)
        for i in 1...arcSegments {
            let angle = CGFloat.pi / 2 + CGFloat(i) / CGFloat(arcSegments) * (CGFloat.pi / 2)
            points.append(CGPoint(x: r + r * cos(angle), y: h - r + r * sin(angle)))
        }

        // 左边（从左下到左上）- 闭合到起点
        points.append(CGPoint(x: 0, y: r))

        // 闭合
        if let first = points.first {
            points.append(first)
        }

        // 生成顶点，带颜色
        var vertices: [PolylineVertex] = []
        for (index, point) in points.enumerated() {
            let t = CGFloat(index) / CGFloat(points.count)
            let colorT = (t + phase).truncatingRemainder(dividingBy: 1.0)
            vertices.append(PolylineVertex(
                position: SIMD2<Float>(Float(point.x), Float(point.y)),
                color: interpolateColor(t: colorT)
            ))
        }

        return vertices
    }

    // 沿 CGPath 均匀采样点
    private func samplePointsAlongPath(_ path: CGPath, count: Int) -> [CGPoint] {
        var allPoints: [CGPoint] = []
        var currentPoint: CGPoint = .zero

        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            let points = element.points

            switch element.type {
            case .moveToPoint:
                currentPoint = points[0]
                allPoints.append(currentPoint)

            case .addLineToPoint:
                let endPoint = points[0]
                self.subdivideLine(from: currentPoint, to: endPoint, into: &allPoints)
                currentPoint = endPoint

            case .addQuadCurveToPoint:
                let cp = points[0]
                let endPoint = points[1]
                self.subdivideQuadCurve(from: currentPoint, control: cp, to: endPoint, into: &allPoints)
                currentPoint = endPoint

            case .addCurveToPoint:
                let cp1 = points[0]
                let cp2 = points[1]
                let endPoint = points[2]
                self.subdivideCubicCurve(from: currentPoint, control1: cp1, control2: cp2, to: endPoint, into: &allPoints)
                currentPoint = endPoint

            case .closeSubpath:
                break

            @unknown default:
                break
            }
        }

        return resamplePoints(allPoints, count: count)
    }

    private func subdivideLine(from p0: CGPoint, to p1: CGPoint, into points: inout [CGPoint]) {
        let steps = 10
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = p0.x + t * (p1.x - p0.x)
            let y = p0.y + t * (p1.y - p0.y)
            points.append(CGPoint(x: x, y: y))
        }
    }

    private func subdivideQuadCurve(from p0: CGPoint, control cp: CGPoint, to p1: CGPoint, into points: inout [CGPoint]) {
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let x = mt * mt * p0.x + 2 * mt * t * cp.x + t * t * p1.x
            let y = mt * mt * p0.y + 2 * mt * t * cp.y + t * t * p1.y
            points.append(CGPoint(x: x, y: y))
        }
    }

    private func subdivideCubicCurve(from p0: CGPoint, control1 cp1: CGPoint, control2 cp2: CGPoint, to p1: CGPoint, into points: inout [CGPoint]) {
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let mt2 = mt * mt
            let mt3 = mt2 * mt
            let t2 = t * t
            let t3 = t2 * t
            let x = mt3 * p0.x + 3 * mt2 * t * cp1.x + 3 * mt * t2 * cp2.x + t3 * p1.x
            let y = mt3 * p0.y + 3 * mt2 * t * cp1.y + 3 * mt * t2 * cp2.y + t3 * p1.y
            points.append(CGPoint(x: x, y: y))
        }
    }

    private func resamplePoints(_ allPoints: [CGPoint], count: Int) -> [CGPoint] {
        guard allPoints.count >= 2 else { return allPoints }

        // 计算累积长度
        var lengths: [CGFloat] = [0]
        for i in 1..<allPoints.count {
            let dx = allPoints[i].x - allPoints[i-1].x
            let dy = allPoints[i].y - allPoints[i-1].y
            lengths.append(lengths[i-1] + sqrt(dx*dx + dy*dy))
        }

        guard let totalLength = lengths.last, totalLength > 0 else { return allPoints }

        // 按长度均匀采样
        var result: [CGPoint] = []
        for i in 0..<count {
            let targetLength = totalLength * CGFloat(i) / CGFloat(count)
            var segmentIndex = 0
            for j in 1..<lengths.count {
                if lengths[j] >= targetLength {
                    segmentIndex = j - 1
                    break
                }
            }

            let segmentStart = lengths[segmentIndex]
            let segmentEnd = lengths[min(segmentIndex + 1, lengths.count - 1)]
            let segmentLength = segmentEnd - segmentStart
            let t: CGFloat = segmentLength > 0 ? (targetLength - segmentStart) / segmentLength : 0

            let p1 = allPoints[segmentIndex]
            let p2 = allPoints[min(segmentIndex + 1, allPoints.count - 1)]
            result.append(CGPoint(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y)))
        }

        return result
    }

    // 颜色插值
    private func interpolateColor(t: CGFloat) -> SIMD4<Float> {
        let count = colors.count
        let scaledT = t * CGFloat(count)
        let index = Int(scaledT) % count
        let nextIndex = (index + 1) % count
        let fraction = Float(scaledT - floor(scaledT))

        let c1 = colors[index]
        let c2 = colors[nextIndex]

        return SIMD4<Float>(
            c1.x + (c2.x - c1.x) * fraction,
            c1.y + (c2.y - c1.y) * fraction,
            c1.z + (c2.z - c1.z) * fraction,
            c1.w + (c2.w - c1.w) * fraction
        )
    }
}

#Preview("PathGradientBorder") {
    ZStack {
        Color.black

        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .frame(width: 400, height: 100)
            .overlay(PathGradientBorder(cornerRadius: 12, lineWidth: 2.5))
    }
    .frame(width: 500, height: 200)
}

// MARK: - 主视图
struct InlineComposerView: View {
    @State private var inputText: String = ""
    @State private var suggestion: String = ""
    @State private var isLoading: Bool = false
    @State private var breathe: Bool = false
    @State private var textHeight: CGFloat = 24  // 初始高度 1 行

    // 结构化结果
    @State private var reasoning: String = ""
    @State private var currentPlan: AnalysisPlan?
    @State private var analysisResult: AnalysisResult?

    // 按需加载的详细解释
    @State private var detailedExplanation: [GrammarPoint]?
    @State private var isLoadingDetail: Bool = false
    @State private var showDetailedExplanation: Bool = false

    // 双击回车发送到 Terminal
    @State private var lastSubmittedText: String = ""
    @State private var hasChecked: Bool = false  // 是否已完成检查

    /// Composer 显示状态（双向绑定到 RioTerminalView）
    @Binding var isShowing: Bool

    /// Composer 输入区高度（双向绑定到 RioTerminalView，用于 layout）
    @Binding var inputHeight: CGFloat

    var onCancel: () -> Void
    var host: HostBridge?

    private var shadowRadius: CGFloat {
        breathe ? 25 : 15
    }

    private var shadowOpacity: Double {
        breathe ? 0.5 : 0.3
    }

    /// 将 suggestion 解析为 Markdown AttributedString
    private var markdownAttributedString: AttributedString {
        do {
            return try AttributedString(markdown: suggestion, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(suggestion)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 输入区（多行）
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(ComposerTheme.accent)
                    .font(.system(size: 14))
                    .padding(.top, 4)

                ComposerTextEditor(text: $inputText, onSubmit: handleEnterSubmit, onOptionEnter: sendToTerminal, textHeight: $textHeight)
                    .frame(height: textHeight)
                    .padding(.top, 4)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(.top, 4)
                } else {
                    Button(action: handleEnterSubmit) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(inputText.isEmpty ? .gray : ComposerTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 结果区（有内容或 loading 时显示）
            if isLoading || analysisResult != nil || !suggestion.isEmpty {
                Divider()
                    .padding(.horizontal, 8)

                if isLoading && reasoning.isEmpty && analysisResult == nil {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("AI 思考中...")
                            .font(.system(size: 13))
                            .foregroundColor(ComposerTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // 状态标签区域
                            if currentPlan != nil {
                                HStack(spacing: 8) {
                                    // 语法状态
                                    statusTag(
                                        title: "语法",
                                        isLoading: analysisResult == nil,
                                        isOK: analysisResult?.fixes?.isEmpty ?? true,
                                        okText: "正确",
                                        issueText: analysisResult.map { "\($0.fixes?.count ?? 0)处错误" } ?? ""
                                    )

                                    // 地道表达状态
                                    if currentPlan?.needIdiomatic == true {
                                        statusTag(
                                            title: "地道",
                                            isLoading: analysisResult == nil,
                                            isOK: analysisResult?.idiomaticSuggestions?.isEmpty ?? true,
                                            okText: "已地道",
                                            issueText: analysisResult.map { "\($0.idiomaticSuggestions?.count ?? 0)条建议" } ?? ""
                                        )
                                    }

                                    // 翻译状态
                                    if currentPlan?.needTranslation == true {
                                        statusTag(
                                            title: "翻译",
                                            isLoading: analysisResult == nil,
                                            isOK: true,
                                            okText: "已完成",
                                            issueText: ""
                                        )
                                    }
                                }
                                .padding(.bottom, 4)
                            }

                            // 详细结果
                            if let result = analysisResult {
                                // 语法修复详情 - 按 category 分组
                                if let fixes = result.fixes, !fixes.isEmpty {
                                    // 按 category 分组
                                    let groupedFixes = Dictionary(grouping: fixes) { $0.category }
                                    // 按分类排序（可选，使用预定义顺序）
                                    let sortedCategories = groupedFixes.keys.sorted { cat1, cat2 in
                                        let order = ["tense", "article", "preposition", "subject_verb_agreement",
                                                   "word_order", "singular_plural", "punctuation", "spelling",
                                                   "word_choice", "sentence_structure", "other"]
                                        let idx1 = order.firstIndex(of: cat1) ?? order.count
                                        let idx2 = order.firstIndex(of: cat2) ?? order.count
                                        return idx1 < idx2
                                    }

                                    resultSection(title: "语法修复", icon: "exclamationmark.triangle") {
                                        ForEach(sortedCategories, id: \.self) { categoryKey in
                                            if let categoryFixes = groupedFixes[categoryKey] {
                                                let grammarCat = GrammarCategory.get(categoryKey)

                                                VStack(alignment: .leading, spacing: 8) {
                                                    // 分类标题
                                                    HStack(spacing: 6) {
                                                        Text(grammarCat.icon)
                                                            .font(.system(size: 14))
                                                        Text(grammarCat.name)
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .foregroundColor(grammarCat.color)
                                                        Text("(\(categoryFixes.count)条)")
                                                            .font(.system(size: 11))
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .padding(.bottom, 4)

                                                    // 该分类下的所有错误
                                                    ForEach(Array(categoryFixes.enumerated()), id: \.offset) { _, fix in
                                                        HStack(alignment: .top, spacing: 8) {
                                                            Text("├─")
                                                                .font(.system(size: 11, design: .monospaced))
                                                                .foregroundColor(.secondary)

                                                            VStack(alignment: .leading, spacing: 4) {
                                                                HStack(spacing: 4) {
                                                                    Text(fix.original)
                                                                        .strikethrough()
                                                                        .foregroundColor(ComposerTheme.danger)
                                                                    Text("→")
                                                                        .foregroundColor(.secondary)
                                                                    Text(fix.corrected)
                                                                        .foregroundColor(ComposerTheme.success)
                                                                }
                                                                .font(.system(size: 12))

                                                                if !fix.errorType.isEmpty {
                                                                    Text(fix.errorType)
                                                                        .font(.system(size: 10))
                                                                        .foregroundColor(.secondary.opacity(0.8))
                                                                }
                                                            }
                                                        }
                                                        .padding(.leading, 8)
                                                    }
                                                }
                                                .padding(.vertical, 6)
                                            }
                                        }
                                    }
                                }

                                // 地道化建议
                                if let suggestions = result.idiomaticSuggestions, !suggestions.isEmpty {
                                    resultSection(title: "地道化建议", icon: "star") {
                                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("当前: \(suggestion.current)")
                                                    .foregroundColor(ComposerTheme.warning)
                                                Text("建议: \(suggestion.idiomatic)")
                                                    .foregroundColor(ComposerTheme.success)
                                                Text(suggestion.explanation)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }

                                // 中英转换
                                if let translations = result.translations, !translations.isEmpty {
                                    resultSection(title: "中英转换", icon: "globe") {
                                        if let pureEnglish = result.pureEnglish, !pureEnglish.isEmpty {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("完整英文版本:")
                                                    .font(.system(size: 12, weight: .semibold))
                                                Text(pureEnglish)
                                                    .foregroundColor(ComposerTheme.success)
                                            }
                                            .padding(.vertical, 4)
                                        }

                                        ForEach(Array(translations.enumerated()), id: \.offset) { _, translation in
                                            HStack(alignment: .top) {
                                                Text("\(translation.chinese) →")
                                                    .foregroundColor(ComposerTheme.warning)
                                                Text(translation.english)
                                                    .foregroundColor(ComposerTheme.success)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }

                                // 按需加载详细解释按钮
                                if !showDetailedExplanation {
                                    Button(action: loadDetailedExplanation) {
                                        HStack(spacing: 4) {
                                            if isLoadingDetail {
                                                ProgressView()
                                                    .scaleEffect(0.6)
                                                Text("加载详细解释...")
                                            } else {
                                                Image(systemName: "book")
                                                Text("查看详细语法解释")
                                            }
                                        }
                                        .font(.system(size: 12))
                                        .foregroundColor(ComposerTheme.accent)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(ComposerTheme.accent.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isLoadingDetail)
                                    .padding(.top, 8)
                                }

                                // 详细语法解释（按需加载后显示）
                                if let points = detailedExplanation, !points.isEmpty {
                                    resultSection(title: "语法详解", icon: "book") {
                                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(point.rule)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(ComposerTheme.accent)
                                                Text(point.explanation)
                                                    .font(.system(size: 12))
                                                if !point.examples.isEmpty {
                                                    Text("示例:")
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundColor(.secondary)
                                                    ForEach(point.examples, id: \.self) { example in
                                                        Text("• \(example)")
                                                            .font(.system(size: 11))
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                            }

                            // 纯文本结果（无结构化分析时的后备显示）
                            if !suggestion.isEmpty && analysisResult == nil {
                                Text(markdownAttributedString)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(maxHeight: 350)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ComposerTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(ComposerTheme.border, lineWidth: 1)
                )
        )
        .overlay(PathGradientBorder(cornerRadius: 14, lineWidth: 2.5))
        .shadow(color: ComposerTheme.accent.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: 8)
        .padding(.horizontal, 20)
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: ComposerInputHeightKey.self,
                        value: geo.size.height
                    )
            }
        )
        .onPreferenceChange(ComposerInputHeightKey.self) { height in
            inputHeight = height
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .background(
            // Escape 键关闭
            Button("") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    /// 辅助方法：创建结果区段
    @ViewBuilder
    private func resultSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(ComposerTheme.accent)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ComposerTheme.accent)
            }
            content()
        }
        .padding(.vertical, 6)
    }

    /// 辅助方法：创建状态标签
    @ViewBuilder
    private func statusTag(title: String, isLoading: Bool, isOK: Bool, okText: String, issueText: String) -> some View {
        let baseColor: Color = {
            if isLoading { return ComposerTheme.textSecondary }
            return isOK ? ComposerTheme.success : ComposerTheme.warning
        }()

        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            } else {
                Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                Text("\(title): \(isOK ? okText : issueText)")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundColor(baseColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(baseColor.opacity(0.12))
        .cornerRadius(6)
    }

    /// Enter 键处理：第一次检查，相同内容第二次发送到 Terminal
    private func handleEnterSubmit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 如果已完成检查且内容相同，发送到 Terminal
        if hasChecked && text == lastSubmittedText {
            sendToTerminal()
            return
        }

        // 否则执行检查
        checkWritingWithTools()
    }

    /// 新的写作检查方法（使用 HostBridge AI）
    private func checkWritingWithTools() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // 记录本次提交的内容
        lastSubmittedText = text
        hasChecked = false

        isLoading = true
        reasoning = ""
        currentPlan = nil
        analysisResult = nil
        suggestion = ""
        // 重置详情状态
        detailedExplanation = nil
        showDetailedExplanation = false

        Task { @MainActor in
            do {
                guard let host = host else {
                    throw WritingError.missingHost
                }

                let model = "qwen-plus"

                // Stage 1: Dispatcher - 分析需要什么检查
                let plan = try await analyzeDispatcher(text, model: model, host: host)
                self.currentPlan = plan
                self.reasoning = plan.reasoning

                // Stage 2: 并行执行具体分析
                let result = try await performAnalysis(text, plan: plan, model: model, host: host)
                self.analysisResult = result
                self.isLoading = false
                self.hasChecked = true  // 标记检查完成

                // 保存语法错误到档案
                if let fixes = result.fixes, !fixes.isEmpty {
                    saveGrammarErrors(fixes, context: text)
                }
            } catch {
                self.isLoading = false
                self.hasChecked = true  // 即使失败也标记完成，允许发送
                self.suggestion = "❌ Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - AI Analysis Methods

    private func analyzeDispatcher(_ text: String, model: String, host: HostBridge) async throws -> AnalysisPlan {
        let system = "You are a dispatcher. Analyze the text and output pure JSON with required booleans and reasoning."
        let user = """
        Analyze this text and decide which checks are needed. Return JSON object with keys:
        - need_grammar_check (boolean)
        - need_fixes (boolean)
        - need_idiomatic (boolean)
        - need_translation (boolean)
        - need_explanation (boolean, default false if unsure)
        - reasoning (string, concise)

        Text:
        \(text)
        """

        let response = try await host.aiChat(model: model, system: system, user: user, extraBody: nil)

        guard let data = response.data(using: .utf8) else {
            throw WritingError.emptyResponse
        }
        return try JSONDecoder().decode(AnalysisPlan.self, from: data)
    }

    private func performAnalysis(_ text: String, plan: AnalysisPlan, model: String, host: HostBridge) async throws -> AnalysisResult {
        var result = AnalysisResult()

        try await withThrowingTaskGroup(of: AnalysisTask?.self) { group in
            if plan.needFixes {
                group.addTask { try await .fixes(self.getFixes(text, model: model, host: host)) }
            }
            if plan.needIdiomatic {
                group.addTask { try await .idiomatic(self.getIdiomaticSuggestions(text, model: model, host: host)) }
            }
            if plan.needTranslation {
                group.addTask { try await self.translateChineseToEnglish(text, model: model, host: host) }
            }
            if plan.needExplanation {
                group.addTask { try await .explanation(self.getDetailedExplanation(text, model: model, host: host)) }
            }

            for try await task in group {
                guard let task else { continue }
                switch task {
                case .fixes(let fixes):
                    result.fixes = fixes
                case .idiomatic(let sug):
                    result.idiomaticSuggestions = sug
                case .translation(let pure, let trs):
                    result.pureEnglish = pure
                    result.translations = trs
                case .explanation(let points):
                    result.grammarPoints = points
                }
            }
        }

        return result
    }

    private func getFixes(_ text: String, model: String, host: HostBridge) async throws -> [GrammarFix] {
        let system = """
        你是语法检查专家。请返回 JSON 格式的语法错误修正。

        分类规则（category 必须从以下选择一个）：
        - tense (时态)
        - article (冠词)
        - preposition (介词)
        - subject_verb_agreement (主谓一致)
        - word_order (词序)
        - singular_plural (单复数)
        - punctuation (标点)
        - spelling (拼写)
        - word_choice (用词)
        - sentence_structure (句子结构)
        - other (其他)
        """

        let user = """
        文本：
        \(text)

        返回 JSON：
        {
          "fixes": [
            {
              "original": "错误的文本片段",
              "corrected": "修正后的文本",
              "error_type": "错误类型的中文描述",
              "category": "分类标识（从上面列表选择，必须是英文）"
            }
          ]
        }

        如果没有语法错误，返回空数组：{"fixes": []}
        """

        let json = try await host.aiChat(model: model, system: system, user: user, extraBody: nil)
        struct Wrapper: Decodable { let fixes: [GrammarFix] }
        guard let data = json.data(using: .utf8) else { throw WritingError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).fixes
    }

    private func getIdiomaticSuggestions(_ text: String, model: String, host: HostBridge) async throws -> [IdiomaticSuggestion] {
        let system = "你是英语写作教练。提供更自然、地道的表达建议，中文解释原因。"
        let user = """
        文本：
        \(text)

        返回 JSON：
        { "suggestions": [ { "current": "...", "idiomatic": "...", "explanation": "..." } ] }
        """

        let json = try await host.aiChat(model: model, system: system, user: user, extraBody: nil)
        struct Wrapper: Decodable { let suggestions: [IdiomaticSuggestion] }
        guard let data = json.data(using: .utf8) else { throw WritingError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).suggestions
    }

    private func translateChineseToEnglish(_ text: String, model: String, host: HostBridge) async throws -> AnalysisTask {
        let system = "You are a translator. Convert Chinese parts to English and also give a mapping list. Only output JSON."
        let user = """
        Text:
        \(text)

        Return JSON:
        {
          "pure_english": "<full English text>",
          "translations": [ { "chinese": "...", "english": "..." } ]
        }
        """

        let json = try await host.aiChat(model: model, system: system, user: user, extraBody: nil)
        struct Wrapper: Decodable { let pure_english: String; let translations: [Translation] }
        guard let data = json.data(using: .utf8) else { throw WritingError.emptyResponse }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return .translation(wrapper.pure_english, wrapper.translations)
    }

    /// 发送内容到 Terminal（带换行）
    private func sendToTerminal() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 通过 HostBridge 写入终端
        if let terminalId = host?.getActiveTerminalId() {
            // 发送内容 + 换行符（执行命令）
            host?.writeToTerminal(terminalId: terminalId, data: text + "\n")
        }

        // 关闭 Composer
        onCancel()
    }

    /// 按需加载详细语法解释
    private func loadDetailedExplanation() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoadingDetail, let host = host else { return }

        isLoadingDetail = true

        Task { @MainActor in
            do {
                let model = "qwen-plus"
                let points = try await getDetailedExplanation(text, model: model, host: host)
                self.detailedExplanation = points
                self.showDetailedExplanation = true
                self.isLoadingDetail = false
            } catch {
                self.isLoadingDetail = false
            }
        }
    }

    private func getDetailedExplanation(_ text: String, model: String, host: HostBridge) async throws -> [GrammarPoint] {
        let system = "你是一位英语语法老师，请用中文给出重要语法点的条目化解释，严格 JSON。"
        let user = """
        文本：
        \(text)

        请返回 JSON:
        {
          "grammar_points": [
            { "rule": "...", "explanation": "...", "examples": ["...", "..."] }
          ]
        }
        """

        let json = try await host.aiChat(model: model, system: system, user: user, extraBody: nil)
        guard let data = json.data(using: .utf8) else { throw WritingError.emptyResponse }
        struct Wrapper: Decodable { let grammar_points: [GrammarPoint] }
        return try JSONDecoder().decode(Wrapper.self, from: data).grammar_points
    }

    /// 保存语法错误到档案
    private func saveGrammarErrors(_ fixes: [GrammarFix], context: String) {
        for fix in fixes {
            WritingDataStore.saveGrammarError(
                original: fix.original,
                corrected: fix.corrected,
                errorType: fix.errorType,
                category: fix.category,
                context: context
            )
        }
    }

}

#Preview {
    ZStack {
        Color.black.opacity(0.3)
        InlineComposerView(
            isShowing: .constant(true),
            inputHeight: .constant(0),
            onCancel: {},
            host: nil
        )
    }
    .frame(width: 800, height: 500)
}
