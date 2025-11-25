//
//  InlineComposerView.swift
//  ETerm
//
//  Inline Writing Assistant - Cmd+K 快捷写作助手
//

import SwiftUI
import AppKit

// MARK: - PreferenceKey for Input Area Height

struct ComposerInputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Custom TextEditor with Enter to Submit

/// 自定义文本编辑器：Enter 发送，Cmd+Enter 换行
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    @Binding var textHeight: CGFloat  // 新增：动态高度绑定

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, textHeight: $textHeight)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

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

        // ScrollView 设置
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

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
        @Binding var textHeight: CGFloat
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void, textHeight: Binding<CGFloat>) {
            self._text = text
            self.onSubmit = onSubmit
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
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // 检查是否有 Command 修饰符
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.command) {
                    // Cmd+Enter：换行
                    textView.insertNewline(nil)
                    return true
                } else {
                    // Enter：发送
                    onSubmit()
                    return true
                }
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

    // 紫粉色系
    private let colors: [SIMD4<Float>] = [
        SIMD4<Float>(0.74, 0.51, 0.95, 1.0),  // 紫
        SIMD4<Float>(0.96, 0.73, 0.92, 1.0),  // 粉
        SIMD4<Float>(0.55, 0.62, 1.0, 1.0),   // 蓝紫
        SIMD4<Float>(0.78, 0.53, 0.93, 1.0),  // 淡紫
        SIMD4<Float>(0.67, 0.43, 0.93, 1.0),  // 深紫
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
    @State private var detailLevel: DetailLevel = .standard

    // 新增：结构化结果
    @State private var reasoning: String = ""
    @State private var analysisResult: AnalysisResult?

    var onCancel: () -> Void
    var coordinator: TerminalWindowCoordinator?

    enum DetailLevel: String, CaseIterable {
        case concise = "简洁"
        case standard = "标准"
        case detailed = "详细"
    }

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
                    .foregroundColor(.purple)
                    .font(.system(size: 14))
                    .padding(.top, 4)

                ComposerTextEditor(text: $inputText, onSubmit: checkWritingWithTools, textHeight: $textHeight)
                    .frame(height: textHeight)
                    .padding(.top, 4)

                // 详细程度选择器
                Picker("", selection: $detailLevel) {
                    ForEach(DetailLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 70)
                .padding(.top, 4)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(.top, 4)
                } else {
                    Button(action: checkWritingWithTools) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(inputText.isEmpty ? .gray : .purple)
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
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // Stage 1: Reasoning
                            if !reasoning.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("分析思路")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.purple)
                                    Text(reasoning)
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Stage 2: 结构化结果
                            if let result = analysisResult {
                                // 语法修复
                                if let fixes = result.fixes, !fixes.isEmpty {
                                    resultSection(title: "语法修复", icon: "exclamationmark.triangle") {
                                        ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text("❌")
                                                    Text(fix.original)
                                                        .strikethrough()
                                                        .foregroundColor(.red)
                                                }
                                                HStack {
                                                    Text("✅")
                                                    Text(fix.corrected)
                                                        .foregroundColor(.green)
                                                }
                                                Text("错误类型: \(fix.errorType)")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }

                                // 地道化建议
                                if let suggestions = result.idiomaticSuggestions, !suggestions.isEmpty {
                                    resultSection(title: "地道化建议", icon: "star") {
                                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("当前: \(suggestion.current)")
                                                    .foregroundColor(.orange)
                                                Text("建议: \(suggestion.idiomatic)")
                                                    .foregroundColor(.green)
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
                                                    .foregroundColor(.green)
                                            }
                                            .padding(.vertical, 4)
                                        }

                                        ForEach(Array(translations.enumerated()), id: \.offset) { _, translation in
                                            HStack(alignment: .top) {
                                                Text("\(translation.chinese) →")
                                                    .foregroundColor(.orange)
                                                Text(translation.english)
                                                    .foregroundColor(.green)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }

                                // 详细语法解释
                                if let points = result.grammarPoints, !points.isEmpty {
                                    resultSection(title: "语法详解", icon: "book") {
                                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(point.rule)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.purple)
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

                            // 兼容旧的纯文本结果
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
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(PathGradientBorder(cornerRadius: 12, lineWidth: 2.5))
        .shadow(color: Color.purple.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: 8)
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
            coordinator?.composerInputHeight = height
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
                    .foregroundColor(.purple)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.purple)
            }
            content()
        }
        .padding(.vertical, 6)
    }

    /// 新的写作检查方法（使用 Tools）
    private func checkWritingWithTools() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        isLoading = true
        reasoning = ""
        analysisResult = nil
        suggestion = ""

        Task { @MainActor in
            do {
                // Stage 1: Dispatcher - 流式显示 reasoning
                let plan = try await OllamaService.shared.analyzeDispatcher(
                    text,
                    detailLevel: detailLevel.rawValue
                ) { updatedReasoning in
                    self.reasoning = updatedReasoning
                }

                // Stage 2: 并行执行具体分析
                let result = try await OllamaService.shared.performAnalysis(text, plan: plan)
                self.analysisResult = result
                self.isLoading = false
            } catch {
                self.isLoading = false
                self.suggestion = "❌ Error: \(error.localizedDescription)"
                print("写作检查失败: \(error)")
            }
        }
    }

    /// 旧的写作检查方法（保留作为后备）
    private func checkWriting() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        isLoading = true
        suggestion = ""

        Task { @MainActor in
            do {
                var hasReceivedContent = false
                try await OllamaService.shared.checkWriting(text) { result in
                    if !hasReceivedContent {
                        hasReceivedContent = true
                        self.isLoading = false
                    }
                    self.suggestion = result
                }
                self.isLoading = false
            } catch {
                self.isLoading = false
                self.suggestion = "❌ Error: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.3)
        InlineComposerView(onCancel: {}, coordinator: nil)
    }
    .frame(width: 800, height: 500)
}
