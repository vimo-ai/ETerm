//
//  DashScopeClient.swift
//  ETerm
//
//  Created by ChatGPT on 2025/02/22.
//

import Foundation

// MARK: - Public data models

struct DashScopeMessage: Codable {
    let role: String
    let content: String
}

struct DashScopeChatResponse: Decodable {
    struct Choice: Decodable {
        let index: Int
        let message: DashScopeMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    let id: String
    let choices: [Choice]
}

struct DashScopeChatChunk: Decodable {
    struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let role: String?
        let content: String?
    }

    let id: String
    let choices: [Choice]
}

struct DashScopeStream {
    let stream: AsyncThrowingStream<DashScopeChatChunk, Error>
    let cancel: () -> Void
}

struct DashScopeAPIError: Decodable {
    let message: String
    let type: String?
    let code: String?
}

enum DashScopeError: Error {
    case missingAPIKey
    case invalidBaseURL
    case requestFailed(status: Int, body: String?)
    case decodingFailed
    case cancelled
}

// MARK: - Client

final class DashScopeClient {
    struct Configuration {
        let apiKey: String
        let baseURL: URL
        let defaultModel: String

        static func fromEnvironment(defaultModel: String = "qwen-plus") throws -> Configuration {
            guard let key = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !key.isEmpty else {
                throw DashScopeError.missingAPIKey
            }

            let base = ProcessInfo.processInfo.environment["DASHSCOPE_BASE_URL"] ?? "https://dashscope.aliyuncs.com/compatible-mode/v1"
            guard let url = URL(string: base) else {
                throw DashScopeError.invalidBaseURL
            }

            return Configuration(apiKey: key, baseURL: url, defaultModel: defaultModel)
        }
    }

    private let config: Configuration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private func debugLog(_ message: String) {
        print("🟡 DashScope: \(message)")
    }

    init(configuration: Configuration, session: URLSession = .shared) {
        self.config = configuration
        self.session = session

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    convenience init(defaultModel: String = "qwen-plus", session: URLSession = .shared) throws {
        let config = try Configuration.fromEnvironment(defaultModel: defaultModel)
        self.init(configuration: config, session: session)
    }

    // 非流式调用
    func chat(messages: [DashScopeMessage], model: String? = nil, temperature: Double? = nil, extraBody: [String: Any]? = nil) async throws -> DashScopeChatResponse {
        let request = try buildRequest(messages: messages, model: model, temperature: temperature, stream: false, extraBody: extraBody)
        debugLog("chat -> url=\(request.url?.absoluteString ?? ""), model=\(model ?? config.defaultModel)")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            debugLog("chat <- status=\(http.statusCode), bytes=\(data.count)")
        }

        try validate(response: response, data: data)
        guard let result = try? decoder.decode(DashScopeChatResponse.self, from: data) else {
            if let body = String(data: data, encoding: .utf8) {
                print("❌ DashScope decode failed, raw body: \(body)")
            }
            throw DashScopeError.decodingFailed
        }
        return result
    }

    // 流式调用，返回 AsyncThrowingStream 和取消函数
    func streamChat(messages: [DashScopeMessage], model: String? = nil, temperature: Double? = nil, extraBody: [String: Any]? = nil) throws -> DashScopeStream {
        let request = try buildRequest(messages: messages, model: model, temperature: temperature, stream: true, extraBody: extraBody)
        let session = session
        let decoder = decoder

        debugLog("streamChat -> url=\(request.url?.absoluteString ?? ""), model=\(model ?? config.defaultModel)")

        var task: Task<Void, Never>?
        let stream = AsyncThrowingStream<DashScopeChatChunk, Error> { continuation in
            task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw DashScopeError.requestFailed(status: -1, body: nil)
                    }

                    guard (200...299).contains(http.statusCode) else {
                        var buffer = Data()
                        for try await chunk in bytes {
                            buffer.append(chunk)
                        }
                        let message = decodeAPIError(from: buffer) ?? String(data: buffer, encoding: .utf8)
                        debugLog("streamChat <- status=\(http.statusCode), body=\(message ?? "<non-utf8>")")
                        throw DashScopeError.requestFailed(status: http.statusCode, body: message)
                    }

                    debugLog("streamChat <- status=\(http.statusCode) (streaming)")

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)

                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(DashScopeChatChunk.self, from: data)
                            continuation.yield(chunk)
                        } catch {
                            if let body = String(data: data, encoding: .utf8) {
                                print("❌ DashScope stream decode failed, raw line: \(body)")
                            }
                            throw error
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DashScopeError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return DashScopeStream(stream: stream) {
            task?.cancel()
        }
    }
}

// MARK: - Private helpers

private extension DashScopeClient {
    func buildRequest(messages: [DashScopeMessage], model: String?, temperature: Double?, stream: Bool, extraBody: [String: Any]? = nil) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model ?? config.defaultModel,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream
        ]
        if let temperature {
            body["temperature"] = temperature
        }
        if let extraBody {
            for (key, value) in extraBody {
                body[key] = value
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func validate(response: URLResponse?, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DashScopeError.requestFailed(status: -1, body: nil)
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMessage = decodeAPIError(from: data) ?? String(data: data, encoding: .utf8)
            debugLog("chat <- status=\(http.statusCode), body=\(errorMessage ?? "<non-utf8>")")
            throw DashScopeError.requestFailed(status: http.statusCode, body: errorMessage)
        }
    }

    func decodeAPIError(from data: Data) -> String? {
        guard let apiError = try? decoder.decode(DashScopeAPIError.self, from: data) else {
            return nil
        }
        return apiError.message
    }
}
