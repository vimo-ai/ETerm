//
//  AICompletionService.swift
//  ETerm
//
//  AI 命令补全服务 - 基于上下文选择最佳历史候选
//

import Foundation

// MARK: - 会话上下文

struct SessionContext {
    var lastCommand: String = ""
    var lastOutput: String = ""        // 最多保留 500 字符
    var lastExitCode: Int = 0
    var pwd: String = ""

    static let empty = SessionContext()
}

// MARK: - 配置

struct AICompletionSettings: Codable {
    var enabled: Bool = true
    var timeout: TimeInterval = 0.15       // 150ms（需 > Ollama 热延迟 80-120ms）
    var cacheTTL: TimeInterval = 5.0
    var unhealthyBackoff: TimeInterval = 30.0
    var maxCandidates: Int = 5
    var maxContextLength: Int = 500

    static var `default`: AICompletionSettings { AICompletionSettings() }
}

// MARK: - 服务

final class AICompletionService: AISocketRequestHandler {
    static let shared = AICompletionService()

    private let settings: AICompletionSettings
    private let ollamaService: OllamaService

    // 会话上下文存储（按 session 隔离）
    private var contexts: [String: SessionContext] = [:]
    private let contextsLock = NSLock()

    // 缓存
    private struct CacheKey: Hashable {
        let sessionId: String
        let input: String
        let candidatesHash: Int
    }

    private struct CacheEntry {
        let index: Int
        let timestamp: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    // 进行中的请求（per-session）
    private var pendingTasks: [String: Task<AISocketResponse, Never>] = [:]
    private let tasksLock = NSLock()

    // 健康状态
    private var unhealthyUntil: Date = .distantPast

    private init() {
        self.settings = .default
        self.ollamaService = OllamaService.shared
    }

    // MARK: - AISocketRequestHandler

    func handleRequest(_ request: AISocketRequest) async -> AISocketResponse {
        print("[AICompletion] 收到请求: \(request.id), input=\(request.input), candidates=\(request.candidates.count)个")

        // 1. 检查是否启用
        guard settings.enabled else {
            print("[AICompletion] 服务未启用")
            return AISocketResponse(id: request.id, index: 0, status: .skip)
        }

        // 2. 检查健康状态
        if Date() < unhealthyUntil {
            print("[AICompletion] 处于不健康期间")
            return AISocketResponse(id: request.id, index: 0, status: .unhealthy)
        }

        // 3. 检查 Ollama 状态
        guard ollamaService.status.isReady else {
            print("[AICompletion] Ollama 未就绪: \(ollamaService.status)")
            markUnhealthy()
            return AISocketResponse(id: request.id, index: 0, status: .unhealthy)
        }
        print("[AICompletion] Ollama 状态正常")

        // 4. 取消该 session 的旧请求
        cancelPendingTask(for: request.sessionId)

        // 5. 检查缓存
        let cacheKey = CacheKey(
            sessionId: request.sessionId,
            input: request.input,
            candidatesHash: request.candidates.hashValue
        )

        if let cached = getCachedEntry(for: cacheKey) {
            return AISocketResponse(id: request.id, index: cached.index, status: .ok)
        }

        // 6. 创建新任务
        let task = Task { [weak self] in
            await self?.processRequest(request, cacheKey: cacheKey) ??
                AISocketResponse(id: request.id, index: 0, status: .skip)
        }

        setPendingTask(task, for: request.sessionId)

        return await task.value
    }

    // MARK: - 上下文管理

    func updateContext(sessionId: String, command: String? = nil, output: String? = nil, exitCode: Int? = nil, pwd: String? = nil) {
        contextsLock.lock()
        defer { contextsLock.unlock() }

        var ctx = contexts[sessionId] ?? SessionContext()

        if let command = command {
            ctx.lastCommand = command
        }
        if let output = output {
            // 只保留最后 500 字符，并移除敏感信息
            ctx.lastOutput = sanitize(String(output.suffix(settings.maxContextLength)))
        }
        if let exitCode = exitCode {
            ctx.lastExitCode = exitCode
        }
        if let pwd = pwd {
            ctx.pwd = pwd
        }

        contexts[sessionId] = ctx
    }

    func clearContext(sessionId: String) {
        contextsLock.lock()
        defer { contextsLock.unlock() }
        contexts.removeValue(forKey: sessionId)
    }

    // MARK: - 私有方法

    private func processRequest(_ request: AISocketRequest, cacheKey: CacheKey) async -> AISocketResponse {
        print("[AICompletion] processRequest 开始")

        // 检查是否被取消
        if Task.isCancelled {
            print("[AICompletion] 请求被取消")
            return AISocketResponse(id: request.id, index: 0, status: .skip)
        }

        // 使用请求里的上下文
        let pwd = request.pwd ?? ""
        let lastCmd = request.lastCmd ?? ""
        let files = request.files ?? ""
        print("[AICompletion] 上下文: pwd=\(pwd), lastCmd=\(lastCmd), files=\(files.prefix(50))")

        // 调用 Ollama
        guard let index = await callOllama(
            input: request.input,
            candidates: request.candidates,  // 现在是 [CandidateInfo]
            pwd: pwd,
            lastCmd: lastCmd,
            files: files
        ) else {
            print("[AICompletion] callOllama 返回 nil")
            return AISocketResponse(id: request.id, index: 0, status: .skip)
        }
        print("[AICompletion] Ollama 返回索引: \(index)")

        // 缓存结果
        setCacheEntry(CacheEntry(index: index, timestamp: Date()), for: cacheKey)

        return AISocketResponse(id: request.id, index: index, status: .ok)
    }

    private func callOllama(input: String, candidates: [CandidateInfo], pwd: String, lastCmd: String, files: String) async -> Int? {
        let prompt = buildPrompt(input: input, candidates: candidates, pwd: pwd, lastCmd: lastCmd, files: files)
        print("[AICompletion] Prompt:\n\(prompt)")

        do {
            let response = try await ollamaService.generate(
                prompt: prompt,
                options: .fast  // 使用快速模式
            )
            print("[AICompletion] Ollama 响应: \(response)")

            let index = parseIndex(from: response, maxIndex: candidates.count - 1)
            print("[AICompletion] 解析索引: \(String(describing: index))")
            return index
        } catch {
            print("[AICompletion] Ollama 调用失败: \(error)")

            if let ollamaError = error as? OllamaError {
                if case .notReady = ollamaError {
                    markUnhealthy()
                }
            }

            return nil
        }
    }

    private func buildPrompt(input: String, candidates: [CandidateInfo], pwd: String, lastCmd: String, files: String) -> String {
        // 构建候选列表，包含频率信息
        let candidateList = candidates.enumerated()
            .map { "\($0.offset): \($0.element.cmd) (×\($0.element.freq))" }
            .joined(separator: "\n")

        // 包含上下文的 prompt
        return """
        pwd: \(pwd)
        files: \(files)
        last: \(lastCmd)
        input: \(input)
        \(candidateList)
        Best? Reply number only:
        """
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

    private func sanitize(_ text: String) -> String {
        // 移除可能的密码、token 等敏感信息
        let patterns = [
            #"(password|passwd|pwd)[:=]\s*\S+"#,
            #"(token|api[_-]?key|secret|credential)[:=]\s*\S+"#,
            #"(authorization|bearer)\s*:\s*\S+"#
        ]

        var result = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1: [REDACTED]"
                )
            }
        }

        return result
    }

    // MARK: - 缓存操作

    private func getCachedEntry(for key: CacheKey) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = cache[key],
              Date().timeIntervalSince(entry.timestamp) < settings.cacheTTL else {
            return nil
        }

        return entry
    }

    private func setCacheEntry(_ entry: CacheEntry, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache[key] = entry

        // 简单的缓存清理（保留最近 100 条）
        if cache.count > 100 {
            let sorted = cache.sorted { $0.value.timestamp > $1.value.timestamp }
            cache = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(50)))
        }
    }

    // MARK: - 任务管理

    private func cancelPendingTask(for sessionId: String) {
        tasksLock.lock()
        defer { tasksLock.unlock() }

        pendingTasks[sessionId]?.cancel()
        pendingTasks.removeValue(forKey: sessionId)
    }

    private func setPendingTask(_ task: Task<AISocketResponse, Never>, for sessionId: String) {
        tasksLock.lock()
        defer { tasksLock.unlock() }

        pendingTasks[sessionId] = task
    }

    // MARK: - 上下文访问

    private func getContext(for sessionId: String) -> SessionContext {
        contextsLock.lock()
        defer { contextsLock.unlock() }

        return contexts[sessionId] ?? .empty
    }

    // MARK: - 健康状态

    private func markUnhealthy() {
        unhealthyUntil = Date().addingTimeInterval(settings.unhealthyBackoff)
    }

    func resetHealth() {
        unhealthyUntil = .distantPast
    }
}

// MARK: - Logging

private func logError(_ message: String) {
    #if DEBUG
    print("[AICompletionService] ERROR: \(message)")
    #endif
}
