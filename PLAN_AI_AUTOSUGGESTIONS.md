# ETerm AI 模块设计

## 背景

为 ETerm 集成本地 AI 能力，基于 Ollama 提供多种智能功能。

## 整体架构

```
┌─────────────────────────────────────────────────────┐
│ ETerm AI 模块                                       │
├─────────────────────────────────────────────────────┤
│ OllamaService (基础设施，公共)                      │
│ ├── 连接管理 (baseURL, timeout)                    │
│ ├── 健康检查 (状态检测, 自动恢复)                  │
│ ├── 模型管理 (检测, 下载引导)                      │
│ └── 生命周期 (预热, 保活, 清理)                    │
├─────────────────────────────────────────────────────┤
│ 功能模块 (都调用 OllamaService)                     │
│ ├── AICompletionService    命令补全                │
│ ├── AIErrorExplainer       错误解释                │
│ ├── AIOutputSummarizer     输出摘要                │
│ ├── AINaturalLanguage      自然语言转命令          │
│ └── ...                    可扩展                  │
├─────────────────────────────────────────────────────┤
│ Ollama (本地推理)                                   │
│ └── qwen3:0.6b (默认)                              │
└─────────────────────────────────────────────────────┘
```

---

# Part 1: OllamaService (基础设施)

## 职责

- 统一管理 Ollama 连接
- 健康检查 & 状态管理
- 模型检测 & 下载引导
- 预热 & 保活
- 为所有 AI 功能模块提供推理接口

## 配置

```swift
struct OllamaSettings: Codable {
    var baseURL: String = "http://localhost:11434"
    var connectionTimeout: TimeInterval = 2.0
    var model: String = "qwen3:0.6b"      // 用户自行修改
    var warmUpOnStart: Bool = true
    var keepAlive: String = "5m"
}
```

## 核心接口

```swift
protocol OllamaServiceProtocol {
    /// 服务状态
    var status: OllamaStatus { get }

    /// 生成 (通用接口)
    func generate(prompt: String, options: GenerateOptions?) async throws -> String

    /// 健康检查
    func checkHealth() async -> Bool

    /// 预热模型
    func warmUp() async
}

enum OllamaStatus {
    case notInstalled
    case notRunning
    case modelNotFound
    case ready
    case error(Error)
}

struct GenerateOptions {
    var numPredict: Int = 100
    var temperature: Double = 0.7
    var stop: [String] = []
}
```

## 实现

```swift
class OllamaService: OllamaServiceProtocol {
    static let shared = OllamaService()

    private let settings: OllamaSettings
    private var _status: OllamaStatus = .notRunning
    private var keepAliveTimer: Timer?

    var status: OllamaStatus { _status }

    // MARK: - 生成

    func generate(prompt: String, options: GenerateOptions? = nil) async throws -> String {
        guard case .ready = _status else {
            throw OllamaError.notReady(status: _status)
        }

        let opts = options ?? GenerateOptions()
        let request = OllamaGenerateRequest(
            model: settings.model,
            prompt: prompt,
            stream: false,
            options: [
                "num_predict": opts.numPredict,
                "temperature": opts.temperature,
                "stop": opts.stop
            ]
        )

        let url = URL(string: "\(settings.baseURL)/api/generate")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(request)
        req.timeoutInterval = settings.connectionTimeout

        let (data, _) = try await URLSession.shared.data(for: req)
        let response = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return response.response
    }

    // MARK: - 健康检查

    func checkHealth() async -> Bool {
        // 1. 检查进程
        guard isOllamaInstalled() else {
            _status = .notInstalled
            return false
        }

        // 2. 检查 API
        guard await isAPIResponding() else {
            _status = .notRunning
            return false
        }

        // 3. 检查模型
        guard await isModelInstalled() else {
            _status = .modelNotFound
            return false
        }

        _status = .ready
        return true
    }

    // MARK: - 预热 & 保活

    func warmUp() async {
        guard settings.warmUpOnStart else { return }

        _ = try? await generate(
            prompt: "hi",
            options: GenerateOptions(numPredict: 1)
        )

        startKeepAlive()
    }

    private func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.ping() }
        }
    }

    private func ping() async {
        _ = try? await generate(prompt: "", options: GenerateOptions(numPredict: 0))
    }
}
```

## 配置文件

```
~/.eterm/
├── config.json              # ETerm 主配置
└── ai/
    └── ollama.json          # Ollama 配置
```

```json
// ~/.eterm/ai/ollama.json
{
  "baseURL": "http://localhost:11434",
  "model": "qwen3:0.6b",
  "warmUpOnStart": true,
  "keepAlive": "5m"
}
```

---

# Part 2: 命令补全 (AICompletionService)

基于 OllamaService，实现智能命令补全。

## 架构

```
┌─────────────────────────────────────────────────────┐
│ Shell 层: eterm-autosuggestions.zsh                 │
│ ├── _zsh_autosuggest_strategy_ai()    ← 新增       │
│ ├── _zsh_autosuggest_strategy_history()            │
│ └── _zsh_autosuggest_strategy_completion()         │
│                     │                               │
│                     │ zsh/net/socket (非阻塞)       │
│                     ↓                               │
├─────────────────────────────────────────────────────┤
│ AICompletionService                                 │
│ ├── Socket Server (~/.eterm/tmp/ai.sock)           │
│ ├── 上下文缓存 (按 session 隔离)                   │
│ ├── 请求节流 + 去重                                │
│ └── 调用 OllamaService.generate()                  │
└─────────────────────────────────────────────────────┘
```

## 协议设计 (JSON)

### 请求 (Shell → ETerm)

```json
{
  "id": "req-001",
  "session_id": "abc-123",
  "input": "git c",
  "candidates": [
    "git commit -m \"\"",
    "git checkout main",
    "git clone"
  ]
}
```

### 响应 (ETerm → Shell)

```json
{
  "id": "req-001",
  "index": 0,
  "status": "ok"
}
```

| status | 说明 |
|--------|------|
| ok | 成功，使用 index 指定的候选 |
| skip | AI 无法决定，fallback 到历史 |
| unhealthy | 服务不健康，暂停 AI 策略 |

**关键设计**：
- AI 只返回索引，不返回命令文本 → 杜绝注入
- 带 request id → 支持取消过期请求

## 数据流

```
1. 用户输入 "git c"
   ↓
2. zsh-autosuggestions 触发 (异步模式)
   ↓
3. _zsh_autosuggest_strategy_ai() 执行:
   a. 检查节流状态，若有进行中请求则取消
   b. 从 $history 获取候选
   c. 通过 zsh/net/socket 非阻塞发送 JSON
   d. 设置 100ms 超时
   ↓
4. ETerm AICompletionService 收到请求:
   a. 检查健康状态
   b. 去重 (相同 input 直接返回缓存)
   c. 整合上下文，调用 Ollama
   d. 返回候选索引
   ↓
5. Shell 收到响应:
   a. 验证 id 匹配
   b. 验证 index 在候选范围内
   c. 使用 candidates[index] 作为建议
```

## 性能指标

| 指标 | 目标值 | 说明 |
|------|--------|------|
| 端到端延迟 | <200ms | 含 socket 通信 + AI 推理 |
| Ollama 热状态 | 80-120ms | 实测数据 |
| Socket 超时 | 150ms | 超时即 fallback (zselect -t 15) |
| 请求节流 | 50ms | 50ms 内新输入取消旧请求 |

## 实现清单

### Phase 1: Shell 层 (eterm-autosuggestions.zsh)

1. **复制 zsh-autosuggestions.zsh**
   - 重命名为 `eterm-autosuggestions.zsh`

2. **新增 AI Strategy (使用 zsh/net/socket)**
   ```zsh
   zmodload zsh/net/socket
   zmodload zsh/zselect
   zmodload zsh/datetime

   typeset -gA _ETERM_AI_LAST_REQ_IDS   # per-session: session_id -> req_id
   typeset -g _ETERM_AI_UNHEALTHY_UNTIL=0

   # JSON 转义函数
   _eterm_json_escape() {
       local str="$1"
       str="${str//\\/\\\\}"      # \ -> \\
       str="${str//\"/\\\"}"      # " -> \"
       str="${str//$'\n'/\\n}"    # newline -> \n
       str="${str//$'\t'/\\t}"    # tab -> \t
       str="${str//$'\r'/\\r}"    # cr -> \r
       print -r -- "$str"
   }

   _zsh_autosuggest_strategy_ai() {
       emulate -L zsh
       setopt EXTENDED_GLOB
       local input="$1"

       # 太短不触发
       (( $#input < 2 )) && return

       # 健康检查：不健康期间跳过
       (( EPOCHSECONDS < _ETERM_AI_UNHEALTHY_UNTIL )) && return

       # 从历史获取候选
       local prefix="${input//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"
       local -a candidates
       candidates=(${(u)${(M)${(v)history}:#${prefix}*}[1,5]})

       # 没候选或只有一个，不需要 AI
       (( ${#candidates} <= 1 )) && return

       # 生成请求 ID (per-session)
       local req_id="req-${RANDOM}-${EPOCHREALTIME}"
       _ETERM_AI_LAST_REQ_IDS[$ETERM_SESSION_ID]="$req_id"

       # JSON 转义 input 和 candidates
       local escaped_input=$(_eterm_json_escape "$input")
       local json_candidates=""
       local c
       for c in "${candidates[@]}"; do
           json_candidates+="\"$(_eterm_json_escape "$c")\","
       done
       json_candidates="[${json_candidates%,}]"

       # 构造 JSON 请求
       local request="{\"id\":\"$req_id\",\"session_id\":\"$ETERM_SESSION_ID\",\"input\":\"$escaped_input\",\"candidates\":$json_candidates}"

       # 非阻塞 socket 连接
       local fd
       if ! zsocket "$ETERM_AI_SOCK" 2>/dev/null; then
           _ETERM_AI_UNHEALTHY_UNTIL=$((EPOCHSECONDS + 10))
           return
       fi
       fd=$REPLY

       # 发送请求 (带换行作为消息边界)
       print -u $fd "$request"

       # 等待响应 (150ms 超时，单位是 1/100 秒)
       zselect -r $fd -t 15
       if (( $? != 0 )); then
           exec {fd}<&-
           return
       fi

       # 读取响应 (带超时)
       local response=""
       if ! read -t 0.1 -u $fd response; then
           exec {fd}<&-
           return
       fi
       exec {fd}<&-

       # 检查是否是当前 session 的当前请求
       [[ "${_ETERM_AI_LAST_REQ_IDS[$ETERM_SESSION_ID]}" != "$req_id" ]] && return

       # 健壮的 JSON 解析
       local status index

       # 提取 status (使用正则)
       if [[ "$response" =~ '"status"[[:space:]]*:[[:space:]]*"([^"]*)"' ]]; then
           status="${match[1]}"
       else
           return
       fi

       if [[ "$status" == "unhealthy" ]]; then
           _ETERM_AI_UNHEALTHY_UNTIL=$((EPOCHSECONDS + 30))
           return
       fi

       [[ "$status" != "ok" ]] && return

       # 提取 index (使用正则，验证是数字)
       if [[ "$response" =~ '"index"[[:space:]]*:[[:space:]]*([0-9]+)' ]]; then
           index="${match[1]}"
       else
           return
       fi

       # 验证 index 范围
       if (( index >= 0 && index < ${#candidates} )); then
           suggestion="${candidates[$((index + 1))]}"
       fi
   }
   ```

3. **修改默认策略**
   ```zsh
   ZSH_AUTOSUGGEST_STRATEGY=(ai history completion)
   ```

4. **配置 socket 路径**
   ```zsh
   export ETERM_AI_SOCK="$HOME/.eterm/tmp/ai.sock"
   ```

### Phase 2: ETerm 应用层 (Swift)

1. **Socket 服务 (单一 socket)**
   ```swift
   class AISocketServer {
       static let shared = AISocketServer()

       private let socketDir: URL = {
           let home = FileManager.default.homeDirectoryForCurrentUser
           return home.appendingPathComponent(".eterm/tmp")
       }()

       private var socketPath: URL {
           socketDir.appendingPathComponent("ai.sock")
       }

       func start() throws {
           // 创建目录，显式设置权限 0700
           try FileManager.default.createDirectory(
               at: socketDir,
               withIntermediateDirectories: true,
               attributes: [.posixPermissions: 0o700]
           )

           // 确保目录权限正确 (可能已存在)
           try FileManager.default.setAttributes(
               [.posixPermissions: 0o700],
               ofItemAtPath: socketDir.path
           )

           // 清理旧 socket (上次 crash 遗留)
           try? FileManager.default.removeItem(at: socketPath)

           // 启动监听...
       }

       func stop() {
           try? FileManager.default.removeItem(at: socketPath)
       }
   }
   ```

2. **请求去重 + 缓存**
   ```swift
   class AICompletionService {
       // 缓存 key: session_id + input + candidates_hash
       struct CacheKey: Hashable {
           let sessionId: String
           let input: String
           let candidatesHash: Int  // candidates 数组的 hash
       }

       struct CacheEntry {
           let index: Int
           let timestamp: Date
       }

       private var cache: [CacheKey: CacheEntry] = [:]
       private let cacheTTL: TimeInterval = 5.0

       // per-session 进行中的请求
       private var pendingTasks: [String: Task<AIResponse, Never>] = [:]

       func handleRequest(_ request: AIRequest) async -> AIResponse {
           // 取消该 session 的旧请求 (不影响其他 session)
           pendingTasks[request.sessionId]?.cancel()

           // 构造缓存 key
           let cacheKey = CacheKey(
               sessionId: request.sessionId,
               input: request.input,
               candidatesHash: request.candidates.hashValue
           )

           // 检查缓存
           if let cached = cache[cacheKey],
              Date().timeIntervalSince(cached.timestamp) < cacheTTL {
               return AIResponse(id: request.id, index: cached.index, status: .ok)
           }

           // 新请求
           let task = Task {
               await processRequest(request, cacheKey: cacheKey)
           }
           pendingTasks[request.sessionId] = task

           return await task.value
       }

       private func processRequest(_ request: AIRequest, cacheKey: CacheKey) async -> AIResponse {
           // 检查是否被取消
           if Task.isCancelled {
               return AIResponse(id: request.id, index: 0, status: .skip)
           }

           // 调用 Ollama...
           guard let index = await callOllama(request) else {
               return AIResponse(id: request.id, index: 0, status: .skip)
           }

           // 缓存结果
           cache[cacheKey] = CacheEntry(index: index, timestamp: Date())

           return AIResponse(id: request.id, index: index, status: .ok)
       }
   }
   ```

3. **健康检查**
   ```swift
   class OllamaHealthChecker {
       private var isHealthy = true
       private var lastCheck: Date = .distantPast
       private let checkInterval: TimeInterval = 5.0

       func check() async -> Bool {
           guard Date().timeIntervalSince(lastCheck) > checkInterval else {
               return isHealthy
           }

           lastCheck = Date()

           do {
               // 简单 ping
               let url = URL(string: "http://localhost:11434/api/tags")!
               let (_, response) = try await URLSession.shared.data(from: url)
               isHealthy = (response as? HTTPURLResponse)?.statusCode == 200
           } catch {
               isHealthy = false
           }

           return isHealthy
       }
   }
   ```

4. **Ollama 调用优化**
   ```swift
   class OllamaClient {
       func complete(input: String, candidates: [String], context: Context) async throws -> Int? {
           let prompt = buildPrompt(input: input, candidates: candidates, context: context)

           let request = OllamaRequest(
               model: "qwen3:0.6b",
               prompt: prompt,
               stream: false,
               options: OllamaOptions(
                   num_predict: 5,        // 只需要输出 1-2 个数字
                   temperature: 0.0,      // 确定性输出
                   stop: ["\n", ".", ",", ":", ";"]  // 不用空格，避免提前停止
               )
           )

           let response = try await send(request)

           // 解析响应，提取第一个数字
           return parseIndex(from: response, maxIndex: candidates.count - 1)
       }

       private func parseIndex(from response: String, maxIndex: Int) -> Int? {
           // 提取第一个数字
           let digits = response.filter { $0.isNumber }
           guard let first = digits.first,
                 let index = Int(String(first)),
                 index >= 0 && index <= maxIndex else {
               return nil
           }
           return index
       }

       private func buildPrompt(input: String, candidates: [String], context: Context) -> String {
           // 截断上下文
           let lastOutput = String(context.lastOutput.suffix(200))
           let lastCmd = context.lastCommand

           // 明确告诉模型只输出数字
           return """
           选择最合适的命令，只回复数字（0-\(candidates.count - 1)）:
           输入: \(input)
           上下文: \(lastCmd) → \(lastOutput.prefix(50))
           候选:
           \(candidates.enumerated().map { "\($0): \($1)" }.joined(separator: "\n"))
           回复: /no_think
           """
       }
   }
   ```

5. **模型预热**
   ```swift
   class AICompletionService {
       func warmUp() {
           Task {
               // 发一个简单请求预热模型
               _ = try? await ollamaClient.complete(
                   input: "test",
                   candidates: ["test1", "test2"],
                   context: .empty
               )
           }
       }
   }
   ```

### Phase 3: 上下文管理

```swift
class SessionContextStore {
    // 按 session 隔离
    private var contexts: [String: SessionContext] = [:]

    struct SessionContext {
        var lastCommand: String = ""
        var lastOutput: String = ""      // 最多保留 500 字符
        var lastExitCode: Int = 0
        var pwd: String = ""
    }

    func update(sessionId: String, output: String) {
        var ctx = contexts[sessionId] ?? SessionContext()
        // 只保留最后 500 字符，并移除敏感信息
        ctx.lastOutput = sanitize(String(output.suffix(500)))
        contexts[sessionId] = ctx
    }

    private func sanitize(_ text: String) -> String {
        // 移除可能的密码、token 等
        text.replacingOccurrences(
            of: #"(password|token|secret|key)[:=]\s*\S+"#,
            with: "$1: [REDACTED]",
            options: .regularExpression
        )
    }
}
```

### Phase 4: 配置

```swift
struct AICompletionSettings: Codable {
    var enabled: Bool = true
    var model: String = "qwen3:0.6b"
    var timeout: TimeInterval = 0.15     // 150ms (需 > Ollama 热延迟 80-120ms)
    var cacheTTL: TimeInterval = 5.0
    var unhealthyBackoff: TimeInterval = 30.0
    var maxCandidates: Int = 5
    var maxContextLength: Int = 500
}
```

---

# Part 3: 用户引导 UI

```swift
struct OllamaSetupView: View {
    @ObservedObject var ollamaService: OllamaService

    var body: some View {
        switch ollamaService.status {
        case .notInstalled:
            VStack {
                Text("需要安装 Ollama")
                Button("打开安装页面") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
                Text("或使用: brew install ollama")
                    .font(.caption)
            }

        case .notRunning:
            VStack {
                Text("Ollama 未运行")
                Button("启动 Ollama") {
                    launchOllama()
                }
            }

        case .modelNotFound:
            VStack {
                Text("需要下载模型: \(ollamaService.settings.model)")
                Button("下载") {
                    downloadModel()
                }
            }

        case .ready:
            Text("AI 已就绪 ✓").foregroundColor(.green)

        case .error(let error):
            Text("错误: \(error.localizedDescription)").foregroundColor(.red)
        }
    }
}
```

---

## 安全考虑

| 问题 | 解决方案 |
|------|----------|
| Socket 权限 | `~/.eterm/tmp/` 在 home 目录下，天然安全 |
| 命令注入 | AI 只返回索引，不返回命令文本 |
| 上下文泄露 | 敏感信息正则过滤 |
| 多 session 隔离 | 按 session id 隔离上下文 |
| 僵尸 socket | App 启动时删除旧 socket，退出时清理 |

## Fallback 策略

```
AI 策略执行
    │
    ├─ 输入太短 (<2 字符) → 跳过
    ├─ 候选 ≤1 个 → 跳过
    ├─ 不健康期间 → 跳过
    ├─ Socket 连接失败 → 标记不健康 10s，跳过
    ├─ 超时 (>100ms) → 跳过
    ├─ 响应 id 不匹配 (被取消) → 跳过
    ├─ index 越界 → 跳过
    └─ 正常 → 使用 candidates[index]

所有跳过情况 → 自动 fallback 到 history 策略
```

## 不做的事情

1. **不做渲染层修改** - 复用 zsh POSTDISPLAY 机制
2. **不做云端 AI** - 仅本地 Ollama
3. **不做复杂 NLP** - 简单选择任务，不做生成
4. **不做自动安装 Ollama** - 用户自行安装，提供引导

## 测试计划

1. **单元测试**
   - JSON 解析
   - 索引验证
   - 上下文截断
   - 敏感信息过滤

2. **集成测试**
   - Socket 通信
   - 超时处理
   - 健康检查
   - 请求取消

3. **性能测试**
   - 端到端延迟
   - 并发请求
   - 内存占用

4. **边界测试**
   - Ollama 未运行
   - 模型未安装
   - 网络异常
   - 大量候选
