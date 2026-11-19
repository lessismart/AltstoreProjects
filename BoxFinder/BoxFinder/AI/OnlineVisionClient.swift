import Foundation

enum OnlineVisionError: LocalizedError, Sendable {
    case invalidProvider
    case invalidModelID(String)
    case missingAPIKey(String)
    case invalidPhotoCount
    case authRejected
    case insufficientCredit
    case rateLimited
    case unsupportedModelOrRequest
    case unavailableHTTP(Int)
    case responseTooLarge
    case timeout
    case networkUnreachable
    case noSuggestions(String)

    var errorDescription: String? {
        switch self {
        case .invalidProvider:
            return "Choose a supported online vision provider."
        case .invalidModelID(let msg):
            return msg
        case .missingAPIKey(let providerName):
            return "Open Photo AI setup and save your \(providerName) API key first."
        case .invalidPhotoCount:
            return "Choose one to four photos."
        case .authRejected:
            return "The provider rejected this API key. Check the key and account access in Photo AI setup."
        case .insufficientCredit:
            return "This account needs API credit. Add credit on the provider's website or choose another provider."
        case .rateLimited:
            return "The provider's rate or usage limit was reached. Wait and retry, or choose another model."
        case .unsupportedModelOrRequest:
            return "This model or request is not supported. Choose an image-capable model from Browse models and try again."
        case .unavailableHTTP(let status):
            return "The provider is unavailable (HTTP \(status)). Retry later or choose another provider."
        case .responseTooLarge:
            return "Provider reply is too large."
        case .timeout:
            return "The provider took too long. Check your internet connection or try another model."
        case .networkUnreachable:
            return "Cannot reach the provider. Check Wi-Fi and internet access."
        case .noSuggestions(let msg):
            return msg
        }
    }
}

struct VisionModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

protocol VisionHTTPClient: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> (statusCode: Int, data: Data)
}

final class NoRedirectHTTPSClient: NSObject, VisionHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never send API keys across HTTP redirects.
        completionHandler(nil)
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 180)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw OnlineVisionError.timeout
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                throw OnlineVisionError.networkUnreachable
            default:
                throw OnlineVisionError.networkUnreachable
            }
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw OnlineVisionError.networkUnreachable
        }
        return (http.statusCode, data)
    }
}

final class OnlineVisionClient: Sendable {
    static let identifyPrompt = """
        These photos show the same household box. Identify DISTINCT visible objects without double counting across photos. Do not invent hidden objects or exact brands. Use short names, broad categories, quantity 1 unless visually clear, and mark ambiguous objects uncertain. Return ONLY JSON: {"items":[{"name":"...","category":"...","quantity":1,"uncertain":true}]}. Use an empty items array if no objects are visible.
        """
    static let maxResponseBytes = 5_000_000

    private let httpClient: VisionHTTPClient

    init(httpClient: VisionHTTPClient = NoRedirectHTTPSClient()) {
        self.httpClient = httpClient
    }

    static func validateModelID(_ rawValue: String, provider: PhotoAiProvider) throws -> String {
        guard provider.isOnline else { throw OnlineVisionError.invalidProvider }
        var model = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .gemini && model.hasPrefix("models/") {
            model = String(model.dropFirst(7))
        }
        let pattern = provider == .gemini
            ? "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$"
            : "^[A-Za-z0-9][A-Za-z0-9._/:-]{0,159}$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              regex.firstMatch(in: model, range: NSRange(location: 0, length: model.utf16.count)) != nil else {
            throw OnlineVisionError.invalidModelID("Enter a valid model ID from the provider's model list.")
        }
        return model
    }

    static func endpointURL(provider: PhotoAiProvider, model: String) throws -> URL {
        switch provider {
        case .openrouter:
            _ = try validateModelID(model, provider: provider)
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .gemini:
            let valid = try validateModelID(model, provider: provider)
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(valid):generateContent")!
        case .offline:
            throw OnlineVisionError.invalidProvider
        }
    }

    static func buildPayload(
        provider: PhotoAiProvider,
        model: String,
        base64Images: [String],
        prompt: String = identifyPrompt
    ) throws -> [String: Any] {
        let validModel = try validateModelID(model, provider: provider)
        switch provider {
        case .gemini:
            var parts: [[String: Any]] = [["text": prompt]]
            for img in base64Images {
                parts.append([
                    "inlineData": [
                        "mimeType": "image/jpeg",
                        "data": img
                    ]
                ])
            }
            return [
                "contents": [
                    [
                        "role": "user",
                        "parts": parts
                    ]
                ],
                "generationConfig": [
                    "responseMimeType": "application/json",
                    "maxOutputTokens": 4096
                ]
            ]
        case .openrouter:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for img in base64Images {
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(img)"]
                ])
            }
            return [
                "model": validModel,
                "stream": false,
                "max_tokens": 4096,
                "reasoning": ["enabled": false],
                "messages": [
                    [
                        "role": "user",
                        "content": content
                    ]
                ]
            ]
        case .offline:
            throw OnlineVisionError.invalidProvider
        }
    }

    static func extractResponseText(provider: PhotoAiProvider, responseJSON: [String: Any]) throws -> String {
        switch provider {
        case .gemini:
            guard let candidates = responseJSON["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw OnlineVisionError.noSuggestions("Gemini could not analyze this image. Try another photo or model.")
            }
            var output = ""
            for part in parts {
                if (part["thought"] as? Bool) == true { continue }
                if let text = part["text"] as? String {
                    output += text
                }
            }
            return output
        case .openrouter:
            guard let choices = responseJSON["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                throw OnlineVisionError.noSuggestions("The provider returned no suggestions. Try another vision model.")
            }
            if let text = message["content"] as? String {
                return text
            }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
            throw OnlineVisionError.noSuggestions("The provider returned no suggestions. Try another vision model.")
        case .offline:
            throw OnlineVisionError.invalidProvider
        }
    }

    static func filterOpenRouterVisionModels(catalogJSON: [String: Any]) -> [VisionModelOption] {
        guard let data = catalogJSON["data"] as? [[String: Any]] else { return [] }
        var result: [VisionModelOption] = []
        for entry in data {
            guard let id = entry["id"] as? String,
                  let architecture = entry["architecture"] as? [String: Any],
                  let inputs = architecture["input_modalities"] as? [String],
                  let outputs = architecture["output_modalities"] as? [String],
                  inputs.contains("image"),
                  outputs.contains("text") else {
                continue
            }
            let name = (entry["name"] as? String) ?? id
            result.append(VisionModelOption(id: id, name: name))
        }
        return result
    }

    func fetchModels(provider: PhotoAiProvider, apiKey: String) async throws -> [VisionModelOption] {
        switch provider {
        case .openrouter:
            let url = URL(string: "https://openrouter.ai/api/v1/models")!
            let json = try await exchange(provider: .openrouter, url: url, apiKey: "", body: nil)
            return Self.filterOpenRouterVisionModels(catalogJSON: json)
        case .gemini:
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw OnlineVisionError.missingAPIKey("Save your Gemini API key before browsing its models.")
            }
            var options: [VisionModelOption] = []
            var pageToken = ""
            for _ in 0..<8 {
                var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
                var queryItems = [URLQueryItem(name: "pageSize", value: "100")]
                if !pageToken.isEmpty {
                    queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
                }
                components.queryItems = queryItems
                let response = try await exchange(provider: .gemini, url: components.url!, apiKey: key, body: nil)
                if let models = response["models"] as? [[String: Any]] {
                    for model in models {
                        guard let fullName = model["name"] as? String,
                              fullName.hasPrefix("models/gemini-"),
                              !fullName.contains("tts"),
                              let methods = model["supportedGenerationMethods"] as? [String],
                              methods.contains("generateContent") else {
                            continue
                        }
                        let shortId = String(fullName.dropFirst(7))
                        let displayName = (model["displayName"] as? String) ?? fullName
                        options.append(VisionModelOption(id: shortId, name: displayName))
                    }
                }
                pageToken = (response["nextPageToken"] as? String) ?? ""
                if pageToken.isEmpty { break }
            }
            return options
        case .offline:
            throw OnlineVisionError.invalidProvider
        }
    }

    func checkConnection(provider: PhotoAiProvider, model: String, apiKey: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OnlineVisionError.missingAPIKey(provider.displayName)
        }
        if provider == .openrouter {
            let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
            _ = try await exchange(provider: .openrouter, url: keyURL, apiKey: key, body: nil)
        }
        let selected = try Self.validateModelID(model, provider: provider)
        let available = try await fetchModels(provider: provider, apiKey: key)
        if available.contains(where: { $0.id == selected }) {
            return "Your key is accepted and '\(selected)' is listed. You can now identify box photos. Actual availability and API charges depend on the provider."
        }
        throw OnlineVisionError.unsupportedModelOrRequest
    }

    func identifyItems(
        provider: PhotoAiProvider,
        model: String,
        apiKey: String,
        jpegBase64Images: [String]
    ) async throws -> [SuggestedItem] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OnlineVisionError.missingAPIKey(provider.displayName)
        }
        guard (1...4).contains(jpegBase64Images.count) else {
            throw OnlineVisionError.invalidPhotoCount
        }
        let endpoint = try Self.endpointURL(provider: provider, model: model)
        let payload = try Self.buildPayload(
            provider: provider,
            model: model,
            base64Images: jpegBase64Images,
            prompt: Self.identifyPrompt
        )
        let response = try await exchange(provider: provider, url: endpoint, apiKey: key, body: payload)
        let text = try Self.extractResponseText(provider: provider, responseJSON: response)
        return try AiJsonParser.parseItems(from: text)
    }

    func detectObjects(
        provider: PhotoAiProvider,
        model: String,
        apiKey: String,
        jpegBase64Image: String
    ) async throws -> [DetectedObject] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OnlineVisionError.missingAPIKey(provider.displayName)
        }
        let endpoint = try Self.endpointURL(provider: provider, model: model)
        let payload = try Self.buildPayload(
            provider: provider,
            model: model,
            base64Images: [jpegBase64Image],
            prompt: PhotoAnnotationStore.prompt
        )
        let response = try await exchange(provider: provider, url: endpoint, apiKey: key, body: payload)
        let text = try Self.extractResponseText(provider: provider, responseJSON: response)
        return try PhotoAnnotationStore.parse(text: text)
    }

    private func exchange(
        provider: PhotoAiProvider,
        url: URL,
        apiKey: String,
        body: [String: Any]?
    ) async throws -> [String: Any] {
        let urlString = url.absoluteString
        let allowedPrefix: String = provider == .openrouter
            ? "https://openrouter.ai/api/v1/"
            : "https://generativelanguage.googleapis.com/v1beta/"
        guard urlString.hasPrefix(allowedPrefix) else {
            throw OnlineVisionError.invalidProvider
        }

        var headers: [String: String] = ["Accept": "application/json"]
        if !apiKey.isEmpty {
            if provider == .gemini {
                headers["x-goog-api-key"] = apiKey
            } else {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
        }

        var bodyData: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }

        let (status, data) = try await httpClient.send(
            method: body == nil ? "GET" : "POST",
            url: url,
            headers: headers,
            body: bodyData
        )

        if status == 401 || status == 403 { throw OnlineVisionError.authRejected }
        if status == 402 { throw OnlineVisionError.insufficientCredit }
        if status == 429 { throw OnlineVisionError.rateLimited }
        if status == 400 || status == 404 { throw OnlineVisionError.unsupportedModelOrRequest }
        if status != 200 { throw OnlineVisionError.unavailableHTTP(status) }

        guard data.count <= Self.maxResponseBytes else {
            throw OnlineVisionError.responseTooLarge
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineVisionError.noSuggestions("The provider returned unreadable JSON.")
        }
        return json
    }
}
