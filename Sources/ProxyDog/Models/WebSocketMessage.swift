import Foundation

/// Direction of a WebSocket message relative to the client.
enum WebSocketDirection: String, Hashable, Sendable {
    /// Client -> server.
    case sent
    /// Server -> client.
    case received
}

/// Kind of WebSocket message, derived from the frame opcode.
enum WebSocketMessageKind: String, Hashable, Sendable {
    case text
    case binary
    case ping
    case pong
    case close

    var label: String {
        switch self {
        case .text: return String(localized: "Text")
        case .binary: return String(localized: "Binary")
        case .ping: return "Ping"
        case .pong: return "Pong"
        case .close: return String(localized: "Close")
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .binary: return "doc.zipper"
        case .ping: return "arrow.triangle.2.circlepath"
        case .pong: return "arrow.triangle.2.circlepath"
        case .close: return "xmark.circle"
        }
    }
}

/// One captured WebSocket message (a fully reassembled data message or a control frame).
struct WebSocketMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    var direction: WebSocketDirection
    var kind: WebSocketMessageKind
    var timestamp: Date
    /// Decoded payload (fragmented frames are reassembled, client masking removed).
    var payload: Data?
    /// Real payload size in bytes, even when `payload` was truncated.
    var byteCount: Int
    /// True when the payload exceeded the capture cap and only a prefix is stored.
    var truncated: Bool

    init(
        id: UUID = UUID(),
        direction: WebSocketDirection,
        kind: WebSocketMessageKind,
        timestamp: Date = Date(),
        payload: Data?,
        byteCount: Int,
        truncated: Bool = false
    ) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
        self.byteCount = byteCount
        self.truncated = truncated
    }

    var text: String? {
        guard let payload, kind == .text || kind == .close else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    var isTextual: Bool {
        kind == .text
    }
}

/// Helpers shared by the engine and the UI for sticking captured messages onto requests.
enum WebSocketCaptureLimits {
    /// Largest payload stored per message; anything beyond is dropped but counted.
    static let maxPayloadBytes = 512 * 1024
    /// Largest number of messages stored per exchange.
    static let maxMessages = 2_000
    /// Largest total payload stored per exchange.
    static let maxTotalPayloadBytes = 4 * 1024 * 1024
}
