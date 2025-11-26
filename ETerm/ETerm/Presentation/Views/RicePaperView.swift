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

// MARK: - 鼠标位置追踪器
class MouseTracker: ObservableObject {
    @Published var position: CGPoint = .zero
    @Published var windowFrame: NSRect = .zero
    private var monitor: Any?

    func startTracking() {
        guard monitor == nil else { return }
        // 只监听 mouseMoved，不监听拖拽事件，避免拖动选择文本时触发背景重绘导致卡顿
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self = self,
                  let window = event.window else { return event }

            // 获取鼠标在窗口中的位置
            let locationInWindow = event.locationInWindow
            // 转换为视图坐标（SwiftUI 坐标系 Y 轴翻转）
            self.windowFrame = window.frame
            self.position = CGPoint(
                x: locationInWindow.x,
                y: window.frame.height - locationInWindow.y
            )
            return event
        }
    }

    func stopTracking() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stopTracking()
    }
}

// MARK: - 主视图
struct RicePaperView<Content: View>: View {
    @StateObject private var mouseTracker = MouseTracker()
    @State private var viewSize: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    let showMountain: Bool
    let overallOpacity: Double
    let content: Content

    // 图片基础路径（开发阶段用文件路径，后续可改为 Assets）
    private let imageBasePath = "/Users/higuaifan/Desktop/shuimo/shuimo-ui/lib/components/template/ricePaper/assets/img/converted"

    // 宣纸纹理路径
    private let textureBasePath = "/Users/higuaifan/Desktop/shuimo/shuimo-ui/cli/build/config/output/public/rice-paper"

    init(showMountain: Bool = true, overallOpacity: Double = 1.0, @ViewBuilder content: () -> Content) {
        self.showMountain = showMountain
        self.overallOpacity = overallOpacity
        self.content = content()
    }

    private var themePath: String {
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
                // 背景色
                backgroundColor
                    .ignoresSafeArea()

                // 山脉
                if showMountain {
                    mountainsView(in: geometry.size)
                }

                // 宣纸纹理叠加层
                ricePaperTextureView(in: geometry.size)

                // 内容
                content
            }
            .onAppear {
                viewSize = geometry.size
                mouseTracker.startTracking()
            }
            .onDisappear {
                mouseTracker.stopTracking()
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
        let textureName = colorScheme == .dark ? "rice-paper-warm.webp" : "rice-paper.webp"
        let texturePath = "\(textureBasePath)/\(textureName)"
        let textureOpacity = colorScheme == .dark ? 0.5 : 0.8

        if let nsImage = NSImage(contentsOfFile: texturePath) {
            TiledImageView(image: nsImage)
                .frame(width: size.width, height: size.height)
                .opacity(textureOpacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 山脉视图
    @ViewBuilder
    private func mountainsView(in size: CGSize) -> some View {
        let xPercent = size.width > 0 ? mouseTracker.position.x / size.width : 0.5
        let yPercent = size.height > 0 ? mouseTracker.position.y / size.height : 0.5
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
        let imagePath = "\(imageBasePath)/\(themePath)/\(layer.imageName).png"

        if let nsImage = NSImage(contentsOfFile: imagePath) {
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
