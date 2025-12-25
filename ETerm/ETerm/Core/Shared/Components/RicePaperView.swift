/**
 * 宣纸背景组件 - Swift 版本
 * 移植自 shuimo-ui 的 MRicePaper 组件
 */
import SwiftUI
import AppKit
import Combine

// MARK: - 山脉图层类型
enum MountainLayerType {
    case base      // 基础层 x * 0.3, y * 0.3
    case mid       // 中间层 x * 0.8, y * 0.8
    case front     // 前景层 (使用 leftFrontRadio)
    case front2    // 前景层2 (使用 rightFrontRadio)
}

// MARK: - 山脉图层数据
struct MountainLayer: Identifiable {
    let id: String
    let imageName: String
    let layerType: MountainLayerType
    let position: MountainPosition

    enum MountainPosition {
        case left, right
    }
}

// MARK: - 鼠标位置追踪视图（基于 NSTrackingArea，无内存泄漏）
struct MouseTrackingView: NSViewRepresentable {
    @Binding var position: CGPoint

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMouseMoved = { [self] point in
            DispatchQueue.main.async {
                self.position = point
            }
        }
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        // 无需更新
    }
}

class MouseTrackingNSView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        // 移除旧的 tracking area
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        // 创建新的 tracking area
        let options: NSTrackingArea.Options = [
            .mouseMoved,           // 追踪鼠标移动
            .activeInActiveApp,    // 仅在 app 激活时追踪
            .inVisibleRect         // 自动跟随可见区域变化
        ]
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        // 获取鼠标在视图中的位置
        let locationInView = convert(event.locationInWindow, from: nil)
        // 转换为 SwiftUI 坐标系（Y 轴翻转）
        let swiftUIPoint = CGPoint(
            x: locationInView.x,
            y: bounds.height - locationInView.y
        )
        onMouseMoved?(swiftUIPoint)
    }

    // 确保视图可以接收鼠标事件
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - 主视图
struct RicePaperView<Content: View>: View {
    @State private var mousePosition: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    let showMountain: Bool
    let overallOpacity: Double
    let content: Content

    // Asset Catalog 资源命名规则：
    // 山脉图片: {theme}-{name}，如 dark-l-base、green-r-mid
    // 纹理图片: rice-paper、rice-paper-warm

    init(showMountain: Bool = true, overallOpacity: Double = 1.0, @ViewBuilder content: () -> Content) {
        self.showMountain = showMountain
        self.overallOpacity = overallOpacity
        self.content = content()
    }

    private var themePrefix: String {
        colorScheme == .dark ? "dark" : "green"
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color(red: 10/255, green: 87/255, blue: 64/255).opacity(0.2)
    }

    // 左侧山脉层
    private var leftMountainLayers: [MountainLayer] {
        [
            MountainLayer(id: "l-base", imageName: "l-base", layerType: .base, position: .left),
            MountainLayer(id: "l-mid", imageName: "l-mid", layerType: .mid, position: .left),
            MountainLayer(id: "l-front", imageName: "l-front", layerType: .front, position: .left),
            MountainLayer(id: "l-front-2", imageName: "l-front-2", layerType: .front2, position: .left),
        ]
    }

    // 右侧山脉层
    private var rightMountainLayers: [MountainLayer] {
        [
            MountainLayer(id: "r-base", imageName: "r-base", layerType: .base, position: .right),
            MountainLayer(id: "r-mid", imageName: "r-mid", layerType: .mid, position: .right),
            MountainLayer(id: "r-front", imageName: "r-front", layerType: .front, position: .right),
            MountainLayer(id: "r-front-2", imageName: "r-front-2", layerType: .front2, position: .right),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 鼠标追踪层（透明，仅用于追踪鼠标位置）
                MouseTrackingView(position: $mousePosition)
                    .allowsHitTesting(false)

                // 背景色
                backgroundColor
                    .ignoresSafeArea()

                // 山脉
                if showMountain {
                    mountainsView(in: geometry.size)
                }

                // 深色模式下的暗化遮罩层
                if colorScheme == .dark {
                    Color.black.opacity(0.75)
                        .ignoresSafeArea()
                }

                // 宣纸纹理叠加层
                ricePaperTextureView(in: geometry.size)

                // 内容
                content
            }
            .onAppear {
                viewSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
            }
            .opacity(overallOpacity)
        }
    }

    // MARK: - 宣纸纹理叠加层
    @ViewBuilder
    private func ricePaperTextureView(in size: CGSize) -> some View {
        let textureName = colorScheme == .dark ? "rice-paper-warm" : "rice-paper"
        let textureOpacity = colorScheme == .dark ? 0.5 : 0.8

        if let nsImage = NSImage(named: textureName) {
            TiledImageView(image: nsImage)
                .frame(width: size.width, height: size.height)
                .opacity(textureOpacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 山脉视图
    @ViewBuilder
    private func mountainsView(in size: CGSize) -> some View {
        let xPercent = size.width > 0 ? mousePosition.x / size.width : 0.5
        let yPercent = size.height > 0 ? mousePosition.y / size.height : 0.5
        // 计算 xMove 和 yMove（Y轴是X轴的0.5倍）
        let xMove = xPercent * 10 - 5
        let yMove = (yPercent * 10 - 5) * 0.5

        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                // 左侧山脉
                ForEach(leftMountainLayers) { layer in
                    mountainImage(layer: layer, xMove: xMove, yMove: yMove, containerWidth: size.width)
                }

                // 右侧山脉
                ForEach(rightMountainLayers) { layer in
                    mountainImage(layer: layer, xMove: xMove, yMove: yMove, containerWidth: size.width)
                }
            }
            .frame(height: size.width * 773 / 4096)  // 按原始比例
            .padding(.bottom, 60)  // 山脉上移
        }
    }

    /// 计算视差偏移
    /// - Parameters:
    ///   - layer: 山脉图层
    ///   - xMove: X轴移动量 (-5 ~ 5)
    ///   - yMove: Y轴移动量 (-2.5 ~ 2.5)
    /// - Returns: (offsetX, offsetY)
    private func calculateParallaxOffset(layer: MountainLayer, xMove: CGFloat, yMove: CGFloat) -> (CGFloat, CGFloat) {
        // 左右差异系数：鼠标往左移时 leftFrontRadio=2，往右移时 rightFrontRadio=2
        let leftFrontRadio: CGFloat = xMove < 0 ? 2 : 1
        let rightFrontRadio: CGFloat = xMove > 0 ? 2 : 1

        // 左右慢速系数：左侧山在左侧时稍微慢一点，右侧山在右侧时稍微慢一点
        let leftSlowRadio: CGFloat = layer.position == .left ? 0.95 : 1
        let rightSlowRadio: CGFloat = layer.position == .right ? 0.95 : 1

        switch layer.layerType {
        case .base:
            return (xMove * 0.3, yMove * 0.3)
        case .mid:
            return (xMove * 0.8, yMove * 0.8)
        case .front:
            // front 层使用 leftFrontRadio
            return (xMove * leftSlowRadio * leftFrontRadio, yMove * leftSlowRadio)
        case .front2:
            // front2 层使用 rightFrontRadio
            return (xMove * rightSlowRadio * rightFrontRadio, yMove * rightSlowRadio)
        }
    }

    @ViewBuilder
    private func mountainImage(layer: MountainLayer, xMove: CGFloat, yMove: CGFloat, containerWidth: CGFloat) -> some View {
        // 从 Asset Catalog 加载: {theme}-{name}，如 dark-l-base、green-r-mid
        let assetName = "\(themePrefix)-\(layer.imageName)"

        if let nsImage = NSImage(named: assetName) {
            let imageSize = nsImage.size
            let scaledWidth = containerWidth * imageSize.width / 4096
            let scaledHeight = scaledWidth * imageSize.height / imageSize.width

            // 使用完善的视差算法计算偏移
            let (offsetX, offsetY) = calculateParallaxOffset(layer: layer, xMove: xMove, yMove: yMove)

            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: scaledWidth, height: scaledHeight)
                .offset(x: offsetX, y: offsetY)
                .frame(maxWidth: .infinity, alignment: layer.position == .left ? .leading : .trailing)
                // 倒影效果
                .modifier(ReflectionModifier())
        }
    }
}

// MARK: - 平铺图片视图
struct TiledImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView {
        let view = TiledNSView()
        view.tiledImage = image
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let tiledView = nsView as? TiledNSView {
            tiledView.tiledImage = image
            tiledView.needsDisplay = true
        }
    }
}

class TiledNSView: NSView {
    var tiledImage: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        guard let image = tiledImage else { return }

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        // 平铺绘制
        let cols = Int(ceil(bounds.width / imageSize.width))
        let rows = Int(ceil(bounds.height / imageSize.height))

        for row in 0..<rows {
            for col in 0..<cols {
                let rect = NSRect(
                    x: CGFloat(col) * imageSize.width,
                    y: CGFloat(row) * imageSize.height,
                    width: imageSize.width,
                    height: imageSize.height
                )
                image.draw(in: rect)
            }
        }
    }
}

// MARK: - 倒影效果
struct ReflectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content

            content
                .scaleEffect(x: 1, y: -1)
                .opacity(0.3)
                .mask(
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .white.opacity(0.5)]),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(height: 50)
                .clipped()
        }
    }
}

// MARK: - Preview
#Preview("RicePaper Light") {
    RicePaperView {
        VStack {
            Text("水墨宣纸背景")
                .font(.largeTitle)
                .foregroundColor(.primary)
            Text("移动鼠标查看视差效果")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    .frame(width: 800, height: 600)
    .preferredColorScheme(.light)
}

#Preview("RicePaper Dark") {
    RicePaperView {
        VStack {
            Text("水墨宣纸背景")
                .font(.largeTitle)
                .foregroundColor(.primary)
            Text("移动鼠标查看视差效果")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    .frame(width: 800, height: 600)
    .preferredColorScheme(.dark)
}
