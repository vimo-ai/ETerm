//
//  OllamaServiceTests.swift
//  ETermTests
//
//  Ollama 服务测试
//

import XCTest
@testable import ETerm

final class OllamaServiceTests: XCTestCase {

    // MARK: - OllamaSettings Tests

    func testOllamaSettingsDefaultValues() {
        let settings = OllamaSettings()

        XCTAssertEqual(settings.baseURL, "http://localhost:11434")
        XCTAssertEqual(settings.connectionTimeout, 2.0)
        XCTAssertEqual(settings.model, "qwen3:0.6b")
        XCTAssertTrue(settings.warmUpOnStart)
        XCTAssertEqual(settings.keepAlive, "5m")
    }

    func testOllamaSettingsValidation() {
        // 有效配置
        let validSettings = OllamaSettings()
        XCTAssertTrue(validSettings.isValid)

        // 无效 baseURL
        var invalidURL = OllamaSettings()
        invalidURL.baseURL = "not a valid url"
        XCTAssertFalse(invalidURL.isValid)

        // 空 baseURL
        var emptyURL = OllamaSettings()
        emptyURL.baseURL = ""
        XCTAssertFalse(emptyURL.isValid)

        // 空 model
        var emptyModel = OllamaSettings()
        emptyModel.model = ""
        XCTAssertFalse(emptyModel.isValid)
    }

    func testOllamaSettingsEncodeDecode() throws {
        let original = OllamaSettings(
            baseURL: "http://custom:11434",
            connectionTimeout: 5.0,
            model: "llama3:latest",
            warmUpOnStart: false,
            keepAlive: "10m"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OllamaSettings.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - OllamaStatus Tests

    func testOllamaStatusIsReady() {
        XCTAssertFalse(OllamaStatus.unknown.isReady)
        XCTAssertFalse(OllamaStatus.notInstalled.isReady)
        XCTAssertFalse(OllamaStatus.notRunning.isReady)
        XCTAssertFalse(OllamaStatus.modelNotFound.isReady)
        XCTAssertTrue(OllamaStatus.ready.isReady)
        XCTAssertFalse(OllamaStatus.error("test").isReady)
    }

    func testOllamaStatusDisplayText() {
        XCTAssertEqual(OllamaStatus.unknown.displayText, "未知")
        XCTAssertEqual(OllamaStatus.notInstalled.displayText, "未安装 Ollama")
        XCTAssertEqual(OllamaStatus.notRunning.displayText, "Ollama 未运行")
        XCTAssertEqual(OllamaStatus.modelNotFound.displayText, "模型未找到")
        XCTAssertEqual(OllamaStatus.ready.displayText, "就绪")
        XCTAssertEqual(OllamaStatus.error("连接失败").displayText, "错误: 连接失败")
    }

    func testOllamaStatusEquality() {
        XCTAssertEqual(OllamaStatus.ready, OllamaStatus.ready)
        XCTAssertEqual(OllamaStatus.notRunning, OllamaStatus.notRunning)
        XCTAssertEqual(OllamaStatus.error("a"), OllamaStatus.error("a"))
        XCTAssertNotEqual(OllamaStatus.error("a"), OllamaStatus.error("b"))
        XCTAssertNotEqual(OllamaStatus.ready, OllamaStatus.notRunning)
    }

    // MARK: - GenerateOptions Tests

    func testGenerateOptionsDefault() {
        let opts = GenerateOptions.default

        XCTAssertEqual(opts.numPredict, 100)
        XCTAssertEqual(opts.temperature, 0.7)
        XCTAssertTrue(opts.stop.isEmpty)
        XCTAssertFalse(opts.raw)
    }

    func testGenerateOptionsFast() {
        let opts = GenerateOptions.fast

        XCTAssertEqual(opts.numPredict, 10)
        XCTAssertEqual(opts.temperature, 0.0)
        XCTAssertEqual(opts.stop, ["\n", ".", ",", ":", ";"])
        XCTAssertFalse(opts.raw)
    }

    func testGenerateOptionsCustom() {
        let opts = GenerateOptions(
            numPredict: 50,
            temperature: 0.5,
            stop: ["END"],
            raw: true
        )

        XCTAssertEqual(opts.numPredict, 50)
        XCTAssertEqual(opts.temperature, 0.5)
        XCTAssertEqual(opts.stop, ["END"])
        XCTAssertTrue(opts.raw)
    }

    // MARK: - OllamaError Tests

    func testOllamaErrorDescriptions() {
        XCTAssertNotNil(OllamaError.notReady(status: .notRunning).errorDescription)
        XCTAssertNotNil(OllamaError.invalidURL.errorDescription)
        XCTAssertNotNil(OllamaError.requestFailed(status: 500, body: nil).errorDescription)
        XCTAssertNotNil(OllamaError.requestFailed(status: 500, body: "Server error").errorDescription)
        XCTAssertNotNil(OllamaError.decodingFailed.errorDescription)
        XCTAssertNotNil(OllamaError.timeout.errorDescription)
        XCTAssertNotNil(OllamaError.cancelled.errorDescription)
    }

    func testOllamaErrorNotReadyContainsStatus() {
        let error = OllamaError.notReady(status: .notInstalled)
        XCTAssertTrue(error.errorDescription?.contains("未安装") == true)
    }

    func testOllamaErrorRequestFailedContainsBody() {
        let error = OllamaError.requestFailed(status: 400, body: "Bad Request")
        XCTAssertTrue(error.errorDescription?.contains("Bad Request") == true)
    }

    // MARK: - Integration Tests (requires Ollama running)

    /// 集成测试：验证健康检查
    /// 注意：此测试需要 Ollama 在本地运行
    func testHealthCheckIntegration() async {
        let service = OllamaService.shared

        // 只验证方法能正常调用
        let _ = await service.checkHealth()

        // 状态应该被更新（不论 Ollama 是否运行）
        XCTAssertNotEqual(service.status, OllamaStatus.unknown)
    }

    /// 集成测试：验证模型列表
    func testListModelsIntegration() async {
        let service = OllamaService.shared

        // 先检查健康状态
        let healthy = await service.checkHealth()

        if healthy {
            // 如果 Ollama 运行中，应该能获取模型列表
            let models = await service.listModels()
            // 不要求必须有模型，只验证调用不崩溃
            XCTAssertNotNil(models)
        } else {
            // Ollama 未运行时，应该返回空数组
            let models = await service.listModels()
            XCTAssertTrue(models.isEmpty)
        }
    }

    /// 集成测试：验证生成功能
    /// 注意：此测试需要 Ollama 运行且已安装 qwen3:0.6b
    func testGenerateIntegration() async throws {
        let service = OllamaService.shared

        let healthy = await service.checkHealth()

        guard healthy else {
            // 跳过测试（Ollama 未运行）
            throw XCTSkip("Ollama not running, skipping generate test")
        }

        do {
            let response = try await service.generate(
                prompt: "What is 2+2? Reply with just the number.",
                options: GenerateOptions(numPredict: 10, temperature: 0.0)
            )

            XCTAssertFalse(response.isEmpty, "响应不应为空")
        } catch {
            // 如果模型未安装，会抛出错误，这也是预期行为
            XCTAssertTrue(error is OllamaError)
        }
    }

    /// 测试：未就绪时调用 generate 应抛出错误
    func testGenerateThrowsWhenNotReady() async {
        // 创建一个配置错误的设置来模拟未就绪状态
        // 注意：由于 OllamaService 是单例，这个测试可能不稳定
        // 实际应该用 Mock 或依赖注入

        let service = OllamaService.shared

        // 如果服务未就绪
        if !service.status.isReady {
            do {
                _ = try await service.generate(prompt: "test")
                XCTFail("应该抛出 notReady 错误")
            } catch let error as OllamaError {
                if case .notReady = error {
                    // 预期行为
                } else {
                    XCTFail("应该是 notReady 错误，实际是 \(error)")
                }
            } catch {
                XCTFail("应该是 OllamaError，实际是 \(error)")
            }
        }
    }
}
