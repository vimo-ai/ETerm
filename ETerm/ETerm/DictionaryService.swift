//
//  DictionaryService.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import Foundation
import AVFoundation

// 词典查询结果数据模型
struct DictionaryWord: Codable {
    let word: String
    let phonetic: String?
    let phonetics: [Phonetic]?
    let meanings: [Meaning]

    struct Phonetic: Codable {
        let text: String?
        let audio: String?
    }

    struct Meaning: Codable {
        let partOfSpeech: String
        let definitions: [Definition]
    }

    struct Definition: Codable {
        let definition: String
        let example: String?
        let synonyms: [String]?
    }
}

class DictionaryService {
    static let shared = DictionaryService()

    private let baseURL = "https://api.dictionaryapi.dev/api/v2/entries/en"
    private var audioPlayer: AVPlayer?

    private init() {}

    // 查询单词
    func lookup(_ word: String) async throws -> DictionaryWord {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let url = URL(string: "\(baseURL)/\(cleanWord)") else {
            print("❌ 无效的 URL")
            throw DictionaryError.invalidWord
        }

        print("🌐 请求 URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ 无效的响应类型")
            throw DictionaryError.requestFailed
        }

        print("📡 HTTP 状态码: \(httpResponse.statusCode)")

        if httpResponse.statusCode == 404 {
            print("❌ 单词未找到 (404)")
            throw DictionaryError.wordNotFound
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ 请求失败: \(httpResponse.statusCode)")
            throw DictionaryError.requestFailed
        }

        // API 返回数组,我们取第一个结果
        do {
            let results = try JSONDecoder().decode([DictionaryWord].self, from: data)

            guard let firstResult = results.first else {
                throw DictionaryError.wordNotFound
            }

            return firstResult
        } catch {
            // 打印详细错误信息用于调试
            print("❌ 解码错误: \(error)")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📄 原始响应: \(jsonString)")
            }
            throw DictionaryError.invalidResponse
        }
    }

    // 播放发音
    func playPronunciation(audioURL: String) {
        guard let url = URL(string: audioURL) else { return }

        audioPlayer = AVPlayer(url: url)
        audioPlayer?.play()
    }

    // 停止播放
    func stopPronunciation() {
        audioPlayer?.pause()
        audioPlayer = nil
    }
}

enum DictionaryError: Error {
    case invalidWord
    case requestFailed
    case wordNotFound
    case invalidResponse

    var localizedDescription: String {
        switch self {
        case .invalidWord:
            return "无效的单词"
        case .requestFailed:
            return "词典查询失败,请检查网络连接"
        case .wordNotFound:
            return "未找到该单词的释义"
        case .invalidResponse:
            return "词典响应格式错误"
        }
    }
}
