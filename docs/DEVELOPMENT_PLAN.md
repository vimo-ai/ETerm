# ETerm DDD 重构开发计划

> 详细的任务分解和工作内容

## 📅 总体时间规划

**总工期**: 2 周（14 天）
**开始日期**: 2025-11-18
**预计完成**: 2025-12-02

---

## 🎯 阶段 1: 搭建领域层骨架

**时间**: 第 1-2 天（11/18 - 11/19）
**目标**: 建立核心领域模型和基础设施

### 任务清单

#### Day 1 上午: 值对象定义

- [ ] **创建 Domain Layer 目录结构**
  ```
  ETerm/Domain/
    ├── ValueObjects/
    │   ├── PanelLayout.swift
    │   ├── PanelBounds.swift
    │   ├── TabMetadata.swift
    │   └── SplitDirection.swift
    ├── Aggregates/
    ├── Events/
    └── Services/
  ```

- [ ] **实现 `SplitDirection.swift`**
  ```swift
  enum SplitDirection {
      case horizontal  // 水平分割（左右）
      case vertical    // 垂直分割（上下）
  }
  ```

- [ ] **实现 `PanelLayout.swift`**
  ```swift
  indirect enum PanelLayout: Equatable {
      case leaf(panelId: UUID)
      case split(
          direction: SplitDirection,
          first: PanelLayout,
          second: PanelLayout,
          ratio: CGFloat
      )

      // 辅助方法
      func allPanelIds() -> [UUID]
      func contains(panelId: UUID) -> Bool
  }
  ```

- [ ] **实现 `PanelBounds.swift`**
  ```swift
  struct PanelBounds: Equatable {
      let x: CGFloat
      let y: CGFloat
      let width: CGFloat
      let height: CGFloat

      var rect: CGRect { ... }
  }
  ```

- [ ] **实现 `TabMetadata.swift`**
  ```swift
  struct TabMetadata: Equatable {
      let title: String
      let icon: TabIcon
      let createdAt: Date
      var lastActivityAt: Date?

      func withTitle(_ title: String) -> TabMetadata
      func withLastActivity(_ date: Date) -> TabMetadata
  }

  enum TabIcon {
      case terminal
      case custom(String)
  }
  ```

#### Day 1 下午: 领域事件基础设施

- [ ] **创建 `DomainEvent.swift`**
  ```swift
  protocol DomainEvent {
      var occurredAt: Date { get }
      var eventId: UUID { get }
  }
  ```

- [ ] **实现具体事件类型**
  - `PanelSplitted`
  - `PanelClosed`
  - `TabCreated`
  - `TabClosed`
  - `TabActivated`
  - `LayoutChanged`

  ```swift
  struct PanelSplitted: DomainEvent {
      let eventId: UUID
      let occurredAt: Date
      let windowId: UUID
      let originalPanelId: UUID
      let newPanelId: UUID
      let direction: SplitDirection
  }
  ```

- [ ] **实现 `EventBus.swift`**
  ```swift
  final class EventBus {
      func publish(_ event: DomainEvent)
      func subscribe<T: DomainEvent>(
          _ eventType: T.Type,
          handler: @escaping (T) -> Void
      )
  }
  ```

#### Day 2 上午: 聚合根基础结构

- [ ] **实现 `TerminalTab.swift`**
  ```swift
  final class TerminalTab {
      // 属性
      let tabId: UUID
      private(set) var metadata: TabMetadata
      private(set) var state: TabState
      private let terminalSession: TerminalSession
      private var domainEvents: [DomainEvent] = []

      // 构造函数
      init(metadata: TabMetadata, terminalSession: TerminalSession)

      // 核心行为（简单实现）
      func activate()
      func deactivate()
      func close()
      func canBeClosed() -> Bool

      // 事件收集
      func collectDomainEvents() -> [DomainEvent]

      // 工厂方法
      static func createDefault() -> TerminalTab
  }

  enum TabState {
      case inactive
      case active
      case closing
  }
  ```

- [ ] **实现 `EditorPanel.swift`**
  ```swift
  final class EditorPanel {
      // 属性
      let panelId: UUID
      private(set) var tabs: [TerminalTab]
      private(set) var activeTabId: UUID?
      private(set) var bounds: PanelBounds
      private var domainEvents: [DomainEvent] = []

      // 构造函数
      init(bounds: PanelBounds, initialTab: TerminalTab)

      // 核心行为（简单实现）
      func addTab(_ tab: TerminalTab, activate: Bool)
      func removeTab(_ tabId: UUID) -> Result<Void, DomainError>
      func activateTab(_ tabId: UUID)
      func canClose() -> Bool
      func canBeSplit() -> Bool

      // 事件收集
      func collectDomainEvents() -> [DomainEvent]
  }
  ```

- [ ] **实现 `TerminalWindow.swift`**
  ```swift
  final class TerminalWindow {
      // 属性
      let windowId: UUID
      private(set) var rootLayout: PanelLayout
      private var panelRegistry: [UUID: EditorPanel]
      private var domainEvents: [DomainEvent] = []

      // 构造函数
      init(windowId: UUID, initialPanel: EditorPanel)

      // 核心行为（占位实现）
      func splitPanel(
          panelId: UUID,
          direction: SplitDirection,
          layoutCalculator: LayoutCalculator
      ) -> Result<UUID, DomainError>

      func closePanel(panelId: UUID) -> Result<Void, DomainError>

      // 事件收集
      func collectDomainEvents() -> [DomainEvent]
  }
  ```

- [ ] **定义 `DomainError.swift`**
  ```swift
  enum DomainError: Error {
      case panelNotFound
      case tabNotFound
      case cannotCloseLastPanel
      case panelCannotBeSplit
      case tabHasRunningProcess
      // ...
  }
  ```

#### Day 2 下午: 单元测试

- [ ] **编写值对象测试**
  - `PanelLayoutTests.swift`
  - `PanelBoundsTests.swift`
  - `TabMetadataTests.swift`

- [ ] **编写聚合根基础测试**
  - `TerminalTabTests.swift`
  - `EditorPanelTests.swift`
  - `TerminalWindowTests.swift`

- [ ] **验收标准检查**
  - ✅ 能创建 `TerminalWindow` 并添加 `EditorPanel`
  - ✅ 能创建 `EditorPanel` 并添加 `TerminalTab`
  - ✅ 领域事件能正常发布和收集

---

## 🎯 阶段 2: 实现布局算法

**时间**: 第 3-4 天（11/20 - 11/21）
**目标**: 实现布局计算的核心逻辑

### 任务清单

#### Day 3 上午: LayoutCalculator 协议

- [ ] **创建 `LayoutCalculator.swift`**
  ```swift
  protocol LayoutCalculator {
      func calculateSplitLayout(
          currentLayout: PanelLayout,
          targetPanelId: UUID,
          direction: SplitDirection
      ) -> PanelLayout

      func calculatePanelBounds(
          layout: PanelLayout,
          containerSize: CGSize
      ) -> [UUID: PanelBounds]

      func calculateRearrangedLayout(
          currentLayout: PanelLayout,
          draggedPanelId: UUID,
          dropTarget: DropTarget
      ) -> PanelLayout
  }

  struct DropTarget {
      let targetPanelId: UUID
      let position: DropPosition
  }

  enum DropPosition {
      case left, right, top, bottom
  }
  ```

#### Day 3 下午: BinaryTreeLayoutCalculator 实现（Part 1）

- [ ] **创建 `BinaryTreeLayoutCalculator.swift`**

- [ ] **实现 `calculateSplitLayout()`**
  ```swift
  func calculateSplitLayout(
      currentLayout: PanelLayout,
      targetPanelId: UUID,
      direction: SplitDirection
  ) -> PanelLayout {
      // 1. 找到目标节点
      guard let targetNode = findNode(in: currentLayout, panelId: targetPanelId) else {
          return currentLayout
      }

      // 2. 创建新的分割节点
      let newPanelId = UUID()
      let splitNode = PanelLayout.split(
          direction: direction,
          first: targetNode,
          second: .leaf(panelId: newPanelId),
          ratio: 0.5
      )

      // 3. 替换原节点
      return replaceNode(
          in: currentLayout,
          target: targetPanelId,
          with: splitNode
      )
  }
  ```

- [ ] **实现辅助方法**
  - `findNode(in:panelId:) -> PanelLayout?`
  - `replaceNode(in:target:with:) -> PanelLayout`

#### Day 4 上午: BinaryTreeLayoutCalculator 实现（Part 2）

- [ ] **实现 `calculatePanelBounds()`**
  ```swift
  func calculatePanelBounds(
      layout: PanelLayout,
      containerSize: CGSize
  ) -> [UUID: PanelBounds] {
      var result: [UUID: PanelBounds] = [:]

      traverseLayout(
          layout,
          bounds: CGRect(origin: .zero, size: containerSize)
      ) { panelId, bounds in
          result[panelId] = PanelBounds(
              x: bounds.origin.x,
              y: bounds.origin.y,
              width: bounds.width,
              height: bounds.height
          )
      }

      return result
  }
  ```

- [ ] **实现 `traverseLayout()` 递归遍历**
  ```swift
  private func traverseLayout(
      _ layout: PanelLayout,
      bounds: CGRect,
      visitor: (UUID, CGRect) -> Void
  ) {
      switch layout {
      case .leaf(let panelId):
          visitor(panelId, bounds)

      case .split(let direction, let first, let second, let ratio):
          let (firstBounds, secondBounds) = splitBounds(
              bounds,
              direction: direction,
              ratio: ratio
          )
          traverseLayout(first, bounds: firstBounds, visitor: visitor)
          traverseLayout(second, bounds: secondBounds, visitor: visitor)
      }
  }
  ```

#### Day 4 下午: 测试和验证

- [ ] **编写单元测试**
  - `BinaryTreeLayoutCalculatorTests.swift`
  - 测试分割算法（垂直/水平）
  - 测试边界计算
  - 测试嵌套分割

- [ ] **测试用例**
  ```swift
  func testVerticalSplit() {
      // Given
      let layout = PanelLayout.leaf(panelId: UUID())
      let calculator = BinaryTreeLayoutCalculator()

      // When
      let newLayout = calculator.calculateSplitLayout(
          currentLayout: layout,
          targetPanelId: panelId,
          direction: .horizontal
      )

      // Then
      // 验证新布局包含两个节点
      // 验证分割比例为 0.5
  }

  func testCalculateBounds() {
      // Given
      let panelId1 = UUID()
      let panelId2 = UUID()
      let layout = PanelLayout.split(
          direction: .horizontal,
          first: .leaf(panelId: panelId1),
          second: .leaf(panelId: panelId2),
          ratio: 0.5
      )
      let calculator = BinaryTreeLayoutCalculator()

      // When
      let bounds = calculator.calculatePanelBounds(
          layout: layout,
          containerSize: CGSize(width: 800, height: 600)
      )

      // Then
      // 验证 panelId1 的 bounds 是 (0, 0, 400, 600)
      // 验证 panelId2 的 bounds 是 (400, 0, 400, 600)
  }
  ```

- [ ] **验收标准检查**
  - ✅ 分割后的布局正确
  - ✅ 边界计算正确
  - ✅ 所有测试通过

---

## 🎯 阶段 3: 实现坐标映射系统

**时间**: 第 5 天（11/22）
**目标**: 统一坐标转换逻辑

### 任务清单

#### Day 5 上午: CoordinateMapper 实现

- [ ] **创建 `CoordinateMapper.swift`**

- [ ] **实现基础坐标转换**
  ```swift
  final class CoordinateMapper {
      private let scale: CGFloat
      private let containerBounds: CGRect

      init(scale: CGFloat, containerBounds: CGRect)

      // Swift ↔ Rust 坐标转换
      func swiftToRust(point: CGPoint) -> CGPoint {
          return CGPoint(
              x: point.x,
              y: containerBounds.height - point.y
          )
      }

      func rustToSwift(point: CGPoint) -> CGPoint {
          return CGPoint(
              x: point.x,
              y: containerBounds.height - point.y
          )
      }

      // 逻辑 ↔ 物理坐标
      func logicalToPhysical(value: CGFloat) -> CGFloat {
          return value * scale
      }

      func physicalToLogical(value: CGFloat) -> CGFloat {
          return value / scale
      }
  }
  ```

- [ ] **实现网格坐标转换**
  ```swift
  func pixelToGrid(
      point: CGPoint,
      paneOrigin: CGPoint,
      paneHeight: CGFloat,
      cellSize: CGSize,
      padding: CGFloat = 10.0
  ) -> (col: UInt16, row: UInt16) {
      // 1. 转换为 Pane 内部坐标
      let relativeX = point.x - paneOrigin.x
      let relativeY = point.y - paneOrigin.y

      // 2. 扣除 padding
      let adjustedX = max(0, relativeX - padding)
      let adjustedY = max(0, relativeY - padding)

      // 3. Y 轴翻转
      let contentHeight = paneHeight - 2 * padding
      let yFromTop = contentHeight - adjustedY

      // 4. 转换为网格坐标
      let col = UInt16(adjustedX / cellSize.width)
      let row = UInt16(max(0, yFromTop / cellSize.height))

      return (col, row)
  }
  ```

- [ ] **实现组合转换**
  ```swift
  func mouseToTerminalGrid(
      mouseLocation: CGPoint,
      paneInfo: PaneInfo,
      cellSize: CGSize
  ) -> (col: UInt16, row: UInt16) {
      // 一步到位：Swift 鼠标位置 → Rust 终端网格
      let rustPoint = swiftToRust(point: mouseLocation)
      let paneOrigin = CGPoint(x: paneInfo.x, y: paneInfo.y)
      return pixelToGrid(
          point: rustPoint,
          paneOrigin: paneOrigin,
          paneHeight: paneInfo.height,
          cellSize: cellSize
      )
  }
  ```

#### Day 5 下午: TerminalRenderConfig 和测试

- [ ] **创建 `TerminalRenderConfig.swift`**
  ```swift
  struct TerminalRenderConfig {
      let x: Float
      let y: Float
      let width: Float
      let height: Float
      let cols: UInt16
      let rows: UInt16

      static func from(
          bounds: PanelBounds,
          mapper: CoordinateMapper,
          fontMetrics: FontMetrics,
          padding: CGFloat = 10.0
      ) -> TerminalRenderConfig {
          // 实现转换逻辑
      }
  }
  ```

- [ ] **创建 `FontMetrics.swift`**
  ```swift
  struct FontMetrics {
      let cellWidth: CGFloat
      let cellHeight: CGFloat
      let lineHeight: CGFloat
  }
  ```

- [ ] **编写单元测试**
  - `CoordinateMapperTests.swift`
  - 测试 Swift ↔ Rust 转换
  - 测试逻辑 ↔ 物理转换
  - 测试网格坐标转换

- [ ] **验收标准检查**
  - ✅ Swift (0, 0) → Rust (0, height)
  - ✅ 鼠标位置正确转换为网格坐标
  - ✅ rows/cols 计算正确

---

## 🎯 阶段 4: 实现 Application Layer

**时间**: 第 6-7 天（11/23 - 11/24）
**目标**: 连接领域层和表示层

### 任务清单

#### Day 6 上午: WindowController 基础

- [ ] **创建 Application Layer 目录结构**
  ```
  ETerm/Application/
    ├── Controllers/
    │   └── WindowController.swift
    └── Events/
        └── ApplicationEvent.swift
  ```

- [ ] **实现 `WindowController.swift` 基础结构**
  ```swift
  @Observable
  final class WindowController {
      // 聚合根
      private let window: TerminalWindow

      // 领域服务
      private let layoutCalculator: LayoutCalculator
      private let coordinateMapper: CoordinateMapper

      // 状态
      private(set) var containerSize: CGSize
      private(set) var fontMetrics: FontMetrics

      // 为 SwiftUI 提供的计算属性
      var panelBounds: [UUID: PanelBounds] {
          layoutCalculator.calculatePanelBounds(
              layout: window.rootLayout,
              containerSize: containerSize
          )
      }

      var panelRenderConfigs: [UUID: TerminalRenderConfig] {
          panelBounds.mapValues { bounds in
              TerminalRenderConfig.from(
                  bounds: bounds,
                  mapper: coordinateMapper,
                  fontMetrics: fontMetrics
              )
          }
      }

      init(
          window: TerminalWindow,
          layoutCalculator: LayoutCalculator,
          coordinateMapper: CoordinateMapper,
          fontMetrics: FontMetrics
      )
  }
  ```

#### Day 6 下午: WindowController 核心方法

- [ ] **实现 `splitPanel()` 方法**
  ```swift
  func splitPanel(panelId: UUID, direction: SplitDirection) {
      let result = window.splitPanel(
          panelId: panelId,
          direction: direction,
          layoutCalculator: layoutCalculator
      )

      switch result {
      case .success(let newPanelId):
          updateLayout()
          publishEvents(window.collectDomainEvents())

      case .failure(let error):
          handleError(error)
      }
  }
  ```

- [ ] **实现 `updateLayout()` 方法**
  ```swift
  private func updateLayout() {
      let configs = panelRenderConfigs

      // 通知 Rust 更新配置
      for (panelId, config) in configs {
          rustBridge.updatePanelConfig(panelId, config: config)
      }

      // 触发重新渲染
      requestRender()
  }
  ```

- [ ] **实现其他核心方法**
  - `closePanel(panelId:)`
  - `rearrangePanels(draggedPanelId:dropTarget:)` (占位)
  - `resizeContainer(newSize:)`

#### Day 7 上午: 事件系统

- [ ] **创建 `ApplicationEvent.swift`**
  ```swift
  protocol ApplicationEvent {
      var occurredAt: Date { get }
  }

  struct PanelSplitCompletedEvent: ApplicationEvent {
      let occurredAt: Date
      let newPanelId: UUID
  }

  struct LayoutUpdatedEvent: ApplicationEvent {
      let occurredAt: Date
      let affectedPanelIds: [UUID]
  }
  ```

- [ ] **实现事件转换**
  ```swift
  extension ApplicationEvent {
      static func from(domainEvent: DomainEvent) -> ApplicationEvent {
          // 转换领域事件为应用事件
      }
  }
  ```

#### Day 7 下午: 集成和测试

- [ ] **实现 RustBridge 占位接口**
  ```swift
  protocol RustBridge {
      func updatePanelConfig(_ panelId: UUID, config: TerminalRenderConfig)
      func renderAllPanels()
  }
  ```

- [ ] **编写集成测试**
  - 测试 `splitPanel()` 完整流程
  - 测试布局更新流程
  - 测试事件发布

- [ ] **验收标准检查**
  - ✅ SwiftUI View 能观察状态变化
  - ✅ 布局变化能触发 Rust 更新
  - ✅ 事件流转正常

---

## 🎯 阶段 5: 重构 Presentation Layer

**时间**: 第 8-9 天（11/25 - 11/26）
**目标**: 重构 UI 层使用新架构

### 任务清单

#### Day 8 上午: 创建新 View 结构

- [ ] **创建 Presentation Layer 目录**
  ```
  ETerm/Presentation/
    ├── Views/
    │   ├── TerminalWindowView.swift
    │   ├── EditorPanelView.swift
    │   ├── PanelHeaderView.swift
    │   └── TabHeaderItemView.swift
    └── ViewModels/ (如果需要)
  ```

- [ ] **实现 `TerminalWindowView.swift`**
  ```swift
  struct TerminalWindowView: View {
      @State private var controller: WindowController

      var body: some View {
          GeometryReader { geometry in
              ZStack {
                  // 背景
                  backgroundImage

                  // Panel 列表
                  ForEach(controller.panels) { panel in
                      EditorPanelView(panel: panel)
                  }
              }
              .onChange(of: geometry.size) { newSize in
                  controller.resizeContainer(newSize: newSize)
              }
          }
      }
  }
  ```

#### Day 8 下午: 实现 Panel 和 Header View

- [ ] **实现 `EditorPanelView.swift`**
  ```swift
  struct EditorPanelView: View {
      let panel: EditorPanel
      let bounds: PanelBounds

      var body: some View {
          VStack(spacing: 0) {
              // Header
              PanelHeaderView(panel: panel)
                  .frame(height: 30)

              // Terminal 内容
              TerminalContentView(activeTab: panel.activeTab)
          }
          .frame(width: bounds.width, height: bounds.height)
          .position(x: bounds.x + bounds.width/2, y: bounds.y + bounds.height/2)
      }
  }
  ```

- [ ] **实现 `PanelHeaderView.swift`**
  ```swift
  struct PanelHeaderView: View {
      let panel: EditorPanel

      var body: some View {
          HStack(spacing: 4) {
              // Tab 列表
              ForEach(panel.tabs) { tab in
                  TabHeaderItemView(
                      tab: tab,
                      isActive: tab.tabId == panel.activeTabId
                  )
                  .onTapGesture {
                      panel.activateTab(tab.tabId)
                  }
              }

              Spacer()

              // 新建 Tab 按钮
              Button(action: { /* 添加 Tab */ }) {
                  Image(systemName: "plus")
              }
          }
          .padding(.horizontal, 8)
          .background(Color.gray.opacity(0.2))
      }
  }
  ```

- [ ] **实现 `TabHeaderItemView.swift`**
  ```swift
  struct TabHeaderItemView: View {
      let tab: TerminalTab
      let isActive: Bool

      var body: some View {
          HStack(spacing: 4) {
              Image(systemName: "terminal")
              Text(tab.metadata.title)

              // 关闭按钮
              Button(action: { /* 关闭 Tab */ }) {
                  Image(systemName: "xmark")
              }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(isActive ? Color.blue : Color.clear)
          .cornerRadius(4)
      }
  }
  ```

#### Day 9 上午: 重构现有 TabTerminalView

- [ ] **重构 `TabTerminalView.swift`**
  - 移除旧的坐标转换逻辑
  - 使用 `WindowController`
  - 使用 `CoordinateMapper`

- [ ] **修复光标偏移问题**
  - 移除 `pixelToGridCoords` 方法
  - 使用 `CoordinateMapper.mouseToTerminalGrid()`
  - 正确设置 padding = 10.0

#### Day 9 下午: UI 优化和测试

- [ ] **添加样式和动画**
  - Header 样式优化
  - Tab 切换动画
  - Panel 高亮效果

- [ ] **UI 测试**
  - 测试 Header 显示
  - 测试 Tab 切换
  - 测试光标位置

- [ ] **验收标准检查**
  - ✅ UI 显示正常
  - ✅ 光标位置正确
  - ✅ Header 和 Tab 显示正常

---

## 🎯 阶段 6: 简化 Rust 层

**时间**: 第 10 天（11/27）
**目标**: 移除 Rust 的布局逻辑

### 任务清单

#### Day 10 上午: 简化 ContextGrid

- [ ] **创建新的简化版 Panel 结构**
  ```rust
  // terminal.rs
  pub struct Panel {
      pane_id: usize,
      terminal: Box<TerminalHandle>,
      rich_text_id: usize,

      // 渲染配置（由 Swift 传入）
      x: f32,
      y: f32,
      width: f32,
      height: f32,
      cols: u16,
      rows: u16,
  }

  pub struct TabManager {
      sugarloaf: *mut SugarloafHandle,
      panels: HashMap<usize, Panel>,  // 不再需要布局树！
  }
  ```

- [ ] **移除 ContextGrid 的布局逻辑**
  - 移除 `right/down/parent` 链表
  - 移除 `calculate_positions_recursive()`
  - 移除 `resize_pane_recursive()`
  - 保留简单的 Panel 存储

#### Day 10 下午: 修改 FFI 接口

- [ ] **添加新的 FFI 函数**
  ```c
  // SugarloafBridge.h

  /// 更新 Panel 的渲染配置
  void tab_manager_update_panel_config(
      TabManagerHandle manager,
      size_t panel_id,
      float x,
      float y,
      float width,
      float height,
      unsigned short cols,
      unsigned short rows
  );

  /// 渲染所有 Panel
  void tab_manager_render_all_panels(TabManagerHandle manager);
  ```

- [ ] **实现 Rust 侧的新方法**
  ```rust
  pub fn update_panel_config(
      &mut self,
      panel_id: usize,
      x: f32,
      y: f32,
      width: f32,
      height: f32,
      cols: u16,
      rows: u16,
  ) {
      if let Some(panel) = self.panels.get_mut(&panel_id) {
          panel.x = x;
          panel.y = y;
          panel.width = width;
          panel.height = height;

          if panel.cols != cols || panel.rows != rows {
              panel.cols = cols;
              panel.rows = rows;
              terminal_resize(&mut *panel.terminal, cols, rows);
          }
      }
  }

  pub fn render_all_panels(&mut self) {
      for panel in self.panels.values_mut() {
          let logical_x = panel.x / self.scale;
          let logical_y = panel.y / self.scale;

          terminal_render_to_sugarloaf(...);
          sugarloaf_set_rich_text_position(...);
      }

      sugarloaf_render(self.sugarloaf);
  }
  ```

- [ ] **移除旧的 FFI 函数**
  - ~~`tab_manager_get_pane_info()`~~ (不再需要)

- [ ] **验收标准检查**
  - ✅ Rust 代码大幅简化
  - ✅ FFI 接口更清晰
  - ✅ 渲染功能正常

---

## 🎯 阶段 7: 实现拖拽重新布局

**时间**: 第 11-12 天（11/28 - 11/29）
**目标**: 实现核心新需求

### 任务清单

#### Day 11 上午: 拖拽手势识别

- [ ] **在 `PanelHeaderView` 中添加拖拽支持**
  ```swift
  struct PanelHeaderView: View {
      @State private var isDragging = false

      var body: some View {
          // ...
          .gesture(
              DragGesture(minimumDistance: 10)
                  .onChanged { value in
                      isDragging = true
                      // 显示拖拽预览
                  }
                  .onEnded { value in
                      handleDrop(at: value.location)
                      isDragging = false
                  }
          )
      }
  }
  ```

- [ ] **实现 Drop Target 检测**
  ```swift
  func calculateDropTarget(
      dragLocation: CGPoint,
      panels: [EditorPanel]
  ) -> DropTarget? {
      // 检测鼠标是否在某个 Panel 的边缘
      for panel in panels {
          let bounds = panel.bounds.rect

          // 检测四个边缘
          if isNearEdge(dragLocation, bounds: bounds, edge: .left) {
              return DropTarget(targetPanelId: panel.id, position: .left)
          }
          // ... 其他边缘
      }

      return nil
  }
  ```

#### Day 11 下午: Drop Zone 预览

- [ ] **实现 `DropZoneView.swift`**
  ```swift
  struct DropZoneView: View {
      let dropTarget: DropTarget
      let bounds: CGRect

      var body: some View {
          Rectangle()
              .fill(Color.blue.opacity(0.3))
              .frame(width: bounds.width, height: bounds.height)
              .position(x: bounds.midX, y: bounds.midY)
              .overlay(
                  RoundedRectangle(cornerRadius: 4)
                      .stroke(Color.blue, lineWidth: 2)
              )
      }
  }
  ```

- [ ] **在拖拽时显示 Drop Zone**

#### Day 12 上午: 完善布局重排算法

- [ ] **实现 `calculateRearrangedLayout()` 完整版**
  ```swift
  func calculateRearrangedLayout(
      currentLayout: PanelLayout,
      draggedPanelId: UUID,
      dropTarget: DropTarget
  ) -> PanelLayout {
      // 1. 移除被拖拽的节点
      let (layoutWithoutDragged, draggedNode) = removeNode(
          from: currentLayout,
          panelId: draggedPanelId
      )

      // 2. 根据 drop 位置插入节点
      return insertNode(
          draggedNode,
          into: layoutWithoutDragged,
          at: dropTarget
      )
  }
  ```

- [ ] **实现辅助方法**
  - `removeNode(from:panelId:)` - 移除节点
  - `insertNode(_:into:at:)` - 插入节点

#### Day 12 下午: 动画和优化

- [ ] **添加 Panel 移动动画**
  ```swift
  .animation(.spring(response: 0.3, dampingFraction: 0.7), value: bounds)
  ```

- [ ] **优化拖拽体验**
  - 添加拖拽阴影
  - 优化 Drop Zone 显示时机
  - 添加拖拽取消逻辑

- [ ] **验收标准检查**
  - ✅ 能拖动 Panel Header
  - ✅ Drop Zone 显示正确
  - ✅ 布局重排正确
  - ✅ 动画流畅

---

## 🎯 阶段 8: 测试和优化

**时间**: 第 13-14 天（11/30 - 12/02）
**目标**: 确保稳定性和性能

### 任务清单

#### Day 13: 集成测试

- [ ] **端到端测试**
  - 测试完整的 Split Panel 流程
  - 测试完整的拖拽重排流程
  - 测试窗口 Resize 流程
  - 测试 Tab 切换流程

- [ ] **边界情况测试**
  - 测试最小/最大窗口尺寸
  - 测试多次嵌套分割
  - 测试极端拖拽场景

- [ ] **性能测试**
  - 测量布局计算耗时
  - 测量 FFI 调用频率
  - 测量渲染帧率

#### Day 14: 优化和收尾

- [ ] **性能优化**
  - 减少不必要的布局计算（添加缓存）
  - 优化 FFI 调用频率（批量更新）
  - 优化动画性能

- [ ] **Bug 修复**
  - 修复测试中发现的问题
  - 改进用户体验

- [ ] **代码清理**
  - 移除调试代码
  - 优化代码结构
  - 添加必要的注释

- [ ] **文档完善**
  - 更新架构文档
  - 编写使用手册
  - 添加代码注释

- [ ] **最终验收**
  - ✅ 所有核心功能正常
  - ✅ 性能满足要求
  - ✅ 无明显 Bug
  - ✅ 代码质量良好

---

## 📊 工作分配建议

### Claude (AI 助手) 负责

1. **代码实现**
   - 编写领域层代码
   - 编写应用层代码
   - 编写基础设施层代码

2. **单元测试**
   - 编写测试用例
   - 执行测试
   - 修复测试失败

3. **文档编写**
   - 代码注释
   - API 文档
   - 设计文档

### 你（开发者）负责

1. **需求确认**
   - 确认功能是否符合预期
   - 提供 UI/UX 反馈
   - 决策关键设计选择

2. **集成测试**
   - 手动测试 UI 功能
   - 验证拖拽体验
   - 验证视觉效果

3. **最终决策**
   - 架构调整决策
   - 优先级调整
   - 发布时机决定

---

## 🎯 每日检查点

每天结束时，确保：
- ✅ 当天任务完成
- ✅ 所有测试通过
- ✅ 代码已提交 Git
- ✅ 验收标准满足

如果某天进度落后，可以调整后续计划或削减非核心功能。

---

## 🚨 风险和应对

### 风险 1: 时间估算不准确

**应对**:
- 每天回顾进度
- 必要时调整计划
- 优先保证核心功能

### 风险 2: 技术难点超预期

**应对**:
- 及时讨论技术方案
- 必要时简化实现
- 记录技术债务

### 风险 3: 需求变更

**应对**:
- 控制范围蔓延
- 新需求进入下一个迭代
- 保持核心目标不变

---

**文档版本**: v1.0
**更新日期**: 2025-11-18
**状态**: Ready to Start
