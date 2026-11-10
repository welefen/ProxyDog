import Foundation

/// Summary of one host seen in the traffic list, used by the sidebar.
struct DomainSummary: Identifiable, Hashable {
    var domain: String
    var count: Int
    var hasFailure: Bool

    var id: String { domain }
}

/// One local app that originated captured traffic.
struct ClientSummary: Identifiable, Hashable {
    var name: String
    var count: Int
    var hasFailure: Bool
    var iconPath: String?

    var id: String { name }
}

/// Sidebar selection.
enum SidebarSelection: Hashable {
    case all
    case pinned
    case client(String)
    case domain(String)
}
