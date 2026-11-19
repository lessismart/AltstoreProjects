import XCTest
@testable import BoxFinder

private final class MockVisionHTTPClient: VisionHTTPClient, @unchecked Sendable {
    var lastMethod: String?
    var lastURL: URL?
    var lastHeaders: [String: String]?
    var lastBody: Data?
    var responder: ((String, URL) -> (Int, Data))?

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> (statusCode: Int, data: Data) {
        lastMethod = method
        lastURL = url
        lastHeaders = headers
        lastBody = body
        if let responder {
            return responder(method, url)
        }
        return (200, Data("{}".utf8))
    }
}

final class OnlineVisionProviderTests: XCTestCase {
    func testOpenRouterCatalogExcludesTextOnlyAndImageGenerationModels() throws {
        let catalogJSON: [String: Any] = [
            "data": [
                ["id": "vision-model", "name": "Vision", "architecture": ["input_modalities": ["text", "image"], "output_modalities": ["text"]]],
                ["id": "text-only", "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]]],
                ["id": "image-gen", "architecture": ["input_modalities": ["image"], "output_modalities": ["image"]]]
            ]
        ]
        let filtered = OnlineVisionClient.filterOpenRouterVisionModels(catalogJSON: catalogJSON)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "vision-model")
    }

    func testOpenRouterAndGeminiPayloadsKeepAPIKeysOutOfBody() throws {
        let orPayload = try OnlineVisionClient.buildPayload(
            provider: .openrouter,
            model: "google/gemini-2.5-flash",
            base64Images: ["FIRST", "SECOND"]
        )
        let messages = orPayload["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 3)
        XCTAssertNil(orPayload["key"])
        XCTAssertNil(orPayload["Authorization"])
        let secondImage = content[2]["image_url"] as! [String: Any]
        XCTAssertEqual(secondImage["url"] as? String, "data:image/jpeg;base64,SECOND")

        let geminiPayload = try OnlineVisionClient.buildPayload(
            provider: .gemini,
            model: "models/gemini-2.5-flash",
            base64Images: ["JPEGDATA"]
        )
        let contents = geminiPayload["contents"] as! [[String: Any]]
        let parts = contents[0]["parts"] as! [[String: Any]]
        let inlineData = parts[1]["inlineData"] as! [String: Any]
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inlineData["data"] as? String, "JPEGDATA")
    }

    func testGeminiSkipsThoughtPartsAndEndpointBlocksInjection() throws {
        let geminiResp: [String: Any] = [
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["thought": true, "text": "hidden reasoning"],
                            ["text": "{\"items\":["],
                            ["text": "{\"name\":\"Cable\",\"quantity\":2}]}"]
                        ]
                    ]
                ]
            ]
        ]
        let text = try OnlineVisionClient.extractResponseText(provider: .gemini, responseJSON: geminiResp)
        let items = try AiJsonParser.parseItems(from: text)
        XCTAssertEqual(items.first?.name, "Cable")
        XCTAssertEqual(items.first?.quantity, 2)

        XCTAssertThrowsError(try OnlineVisionClient.endpointURL(provider: .gemini, model: "model?key=abc"))
        XCTAssertThrowsError(try OnlineVisionClient.endpointURL(provider: .offline, model: "anything"))
    }

    func testConnectionCheckNeverUploadsPhotosAndMapsAuthErrors() async throws {
        let mock = MockVisionHTTPClient()
        mock.responder = { _, url in
            if url.path.hasSuffix("/key") {
                return (200, Data("{\"data\":{}}".utf8))
            }
            return (200, Data("{\"data\":[{\"id\":\"qwen/qwen3.7-flash\",\"name\":\"Qwen 3.7 Flash\",\"architecture\":{\"input_modalities\":[\"image\"],\"output_modalities\":[\"text\"]}}]}".utf8))
        }
        let client = OnlineVisionClient(httpClient: mock)
        let message = try await client.checkConnection(
            provider: .openrouter,
            model: "qwen/qwen3.7-flash",
            apiKey: "sk-or-test-key-123456"
        )
        XCTAssertTrue(message.contains("qwen/qwen3.7-flash"))
        XCTAssertNil(mock.lastBody)
        XCTAssertEqual(mock.lastMethod, "GET")

        mock.responder = { _, _ in (401, Data("{\"error\":\"Unauthorized\"}".utf8)) }
        do {
            _ = try await client.checkConnection(provider: .openrouter, model: "qwen/qwen3.7-flash", apiKey: "sk-bad")
            XCTFail("Expected auth error")
        } catch OnlineVisionError.authRejected {
            // expected
        }
    }
}
