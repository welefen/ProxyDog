import Foundation

/// Calls mainstream LLM APIs directly from the app (no backend).
enum AIClient {
    static func summarize(configuration: AIConfiguration, prompt: String) async throws -> String {
        guard configuration.isUsable else { throw AIClientError.missingConfiguration }
        switch configuration.provider {
        case .openAI, .deepSeek, .doubao, .kimi, .qwen, .zhipu, .siliconFlow, .openRouter, .custom:
            return try await openAICompatible(configuration: configuration, prompt: prompt)
        case .anthropic:
            return try await anthropic(configuration: configuration, prompt: prompt)
        case .gemini:
            return try await gemini(configuration: configuration, prompt: prompt)
        }
    }

    private static func openAICompatible(configuration: AIConfiguration, prompt: String) async throws -> String {
        let base = configuration.resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { throw AIClientError.missingConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": configuration.resolvedModel,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.2,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        guard
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AIClientError.invalidResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func anthropic(configuration: AIConfiguration, prompt: String) async throws -> String {
        let base = configuration.resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else { throw AIClientError.missingConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": configuration.resolvedModel,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        guard
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw AIClientError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gemini(configuration: AIConfiguration, prompt: String) async throws -> String {
        let base = configuration.resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = configuration.resolvedModel
        guard var components = URLComponents(string: base + "/models/\(model):generateContent") else {
            throw AIClientError.missingConfiguration
        }
        components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        guard let url = components.url else { throw AIClientError.missingConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { throw AIClientError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIClientError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw AIClientError.httpStatus(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }
        return json
    }
}
