import Foundation

/// One HTTP header line.
struct HeaderField: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(name: String, value: String) {
        self.id = UUID()
        self.name = name
        self.value = value
    }

    static func == (lhs: HeaderField, rhs: HeaderField) -> Bool {
        lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame && lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name.lowercased())
        hasher.combine(value)
    }

    var isSensitive: Bool {
        let lowered = name.lowercased()
        return lowered == "authorization"
            || lowered == "cookie"
            || lowered == "set-cookie"
            || lowered == "proxy-authorization"
    }
}

extension Array where Element == HeaderField {
    func firstValue(forName name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentLength: Int? {
        firstValue(forName: "Content-Length").flatMap(Int.init)
    }
}
