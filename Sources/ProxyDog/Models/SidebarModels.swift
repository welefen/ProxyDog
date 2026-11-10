import Foundation

/// Summary of one host seen in the traffic list, used by the sidebar.
struct DomainSummary: Identifiable, Hashable {
    var domain: String
    var count: Int
    var hasFailure: Bool

    var id: String { domain }
}

/// Sidebar selection.
enum SidebarSelection: Hashable {
    case all
    case pinned
    case domain(String)
}
