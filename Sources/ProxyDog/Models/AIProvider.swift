import Foundation

/// LLM providers the analysis sheet can call directly.
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case openAI
    case deepSeek
    case anthropic
    case gemini
    case custom

    var id: String { rawValue }

    /// Provider names stay untranslated: users recognize the brand names.
    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .custom: return String(localized: "Custom (OpenAI compatible)")
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .anthropic: return "claude-3-5-haiku-latest"
        case .gemini: return "gemini-2.0-flash"
        case .custom: return ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .custom: return ""
        }
    }

    var requiresBaseURL: Bool { self == .custom }
}

struct AIConfiguration {
    var provider: AIProvider
    var apiKey: String
    var baseURL: String
    var model: String

    var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultBaseURL : trimmed
    }

    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    var isUsable: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resolvedModel.isEmpty
            && !resolvedBaseURL.isEmpty
    }
}

enum AIClientError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case httpStatus(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return String(localized: "Enter an API key and model before analyzing.")
        case .invalidResponse:
            return String(localized: "The AI provider returned an unexpected response.")
        case .httpStatus(let status, let body):
            let detail = body.isEmpty ? "" : ": \(body.prefix(240))"
            return String(format: String(localized: "The AI provider returned HTTP %d"), status) + detail
        case .transport(let message):
            return message
        }
    }
}
