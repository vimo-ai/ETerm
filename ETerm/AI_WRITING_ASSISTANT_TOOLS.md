# AI 写作助手 - Tools 方案实现说明

## 概述

实现了两阶段 AI Tools 方案，替代原有的复杂 prompt + 文本解析方式。

## 架构设计

### Stage 1: AI Dispatcher（分发器）
- AI 分析文本，自主决定需要哪些深度的检查
- 返回 `AnalysisPlan`，指明需要调用哪些具体分析
- 支持流式显示 `reasoning`（分析思路）

### Stage 2: 并行执行具体分析
- 根据 dispatcher 的决定，并行调用需要的 tools
- 使用 Swift Concurrency 的 `TaskGroup` 实现并行执行
- 返回结构化的 `AnalysisResult`

## 数据结构

### AnalysisPlan（分析计划）
```swift
struct AnalysisPlan {
    let needGrammarCheck: Bool      // 是否需要语法检查
    let needFixes: Bool             // 是否需要修复方案
    let needIdiomatic: Bool         // 是否需要地道化建议
    let needTranslation: Bool       // 是否需要中英转换
    let needExplanation: Bool       // 是否需要详细解释
    let reasoning: String           // 分析思路（流式显示）
}
```

### AnalysisResult（分析结果）
```swift
struct AnalysisResult {
    var fixes: [GrammarFix]?                    // 语法修复列表
    var idiomaticSuggestions: [IdiomaticSuggestion]?  // 地道化建议列表
    var pureEnglish: String?                    // 纯英文版本
    var translations: [Translation]?            // 中英转换对照
    var grammarPoints: [GrammarPoint]?          // 语法点详解
}
```

### 子结构
- `GrammarFix`: 语法错误及修复
- `IdiomaticSuggestion`: 地道化建议
- `Translation`: 中英转换对
- `GrammarPoint`: 语法点详解（含规则、解释、示例）

## API 方法

### OllamaService

#### analyzeDispatcher
```swift
func analyzeDispatcher(
    _ text: String,
    detailLevel: String = "standard",
    onReasoning: @escaping (String) -> Void
) async throws -> AnalysisPlan
```
- 参数 `detailLevel`: "简洁"/"标准"/"详细" - 作为提示而非规则
- 参数 `onReasoning`: 流式回调，实时显示 AI 的分析思路
- 返回: 分析计划

#### performAnalysis
```swift
func performAnalysis(_ text: String, plan: AnalysisPlan) async throws -> AnalysisResult
```
- 并行执行多个 tool 调用
- 根据 plan 动态决定调用哪些 tools
- 返回: 结构化的分析结果

### 内部 Tools
- `getFixes`: 语法修复
- `getIdiomaticSuggestions`: 地道化建议
- `translateChineseToEnglish`: 中英转换
- `getDetailedExplanation`: 详细语法解释

## UI 实现

### InlineComposerView 新特性

1. **详细程度选择器**
   - 简洁/标准/详细三档
   - 作为 AI 提示，而非强制规则

2. **结构化结果显示**
   - 分析思路（流式显示）
   - 语法修复（红叉 → 绿勾）
   - 地道化建议（当前 → 建议 + 解释）
   - 中英转换（对照显示）
   - 语法详解（规则 + 解释 + 示例）

3. **兼容性**
   - 保留旧的 `checkWriting` 方法作为后备
   - 默认使用新的 `checkWritingWithTools` 方法

## 测试建议

### 测试用例

1. **纯英文（无错误）**
   ```
   I am a software engineer.
   ```
   预期: AI 可能只建议地道化（如果有更好的表达）

2. **英文（有语法错误）**
   ```
   He go to school yesterday.
   ```
   预期: 语法修复（go → went）

3. **中英混合**
   ```
   I want to 学习 English.
   ```
   预期: 中英转换（学习 → learn）

4. **复杂句式**
   ```
   If I had known about this, I would have done differently.
   ```
   预期: 详细程度选择"详细"时会给出虚拟语气解释

### 测试步骤

1. 启动 ETerm
2. 按 Cmd+K 唤起写作助手
3. 输入测试文本
4. 选择详细程度（简洁/标准/详细）
5. 按 Enter 提交
6. 观察：
   - 分析思路是否流式显示
   - 结果是否分区清晰
   - 并行执行是否正常

## 技术亮点

1. **结构化返回**: 使用 Ollama Tools API，避免复杂的文本解析
2. **并发执行**: Swift TaskGroup 并行调用多个 tools，提升效率
3. **流式体验**: Dispatcher 的 reasoning 流式显示，用户体验更好
4. **灵活控制**: AI 自主决定检查深度，用户偏好作为提示
5. **类型安全**: 完整的 Codable 结构，编译时类型检查

## 注意事项

1. **Ollama 版本**: 需要支持 Tools 的 Ollama 版本（建议 0.1.0+）
2. **模型支持**: 确保模型支持 function calling（qwen3:8b 支持）
3. **错误处理**: 完善的错误处理，失败时显示错误信息
4. **性能**: 并行调用多个 tools 时注意 API 并发限制

## 后续优化方向

1. 添加用户反馈机制（点赞/踩）
2. 缓存分析结果，避免重复分析
3. 支持用户自定义 tools
4. 添加分析历史记录
5. 支持更多语言对（如英日、英法等）

## 文件清单

- `/ETerm/ETerm/OllamaService.swift` - 核心 AI 服务
- `/ETerm/ETerm/Presentation/Views/InlineComposerView.swift` - UI 界面
