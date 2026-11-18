import Foundation

/// Where a link should go. Pure so it can be tested without a web view.
public enum LinkRoute: Equatable, Sendable {
    /// Load it in this web view.
    case stay
    /// Hand it to the system: Safari for other sites, the owning app for mailto:, tel: and the like.
    case external
    /// Never follow: script, data and file URLs.
    case block

    /// `householdHosts` are the hosts that stay in the app (Home Base and the member's apps); every other
    /// web address opens in Safari, so the app never becomes a general-purpose browser.
    public static func of(_ url: URL, householdHosts: Set<String>) -> LinkRoute {
        switch url.scheme?.lowercased() {
        case "https":
            return householdHosts.contains(url.host()?.lowercased() ?? "") ? .stay : .external
        case "http":
            return .external
        case "about":
            return url.absoluteString == "about:blank" ? .stay : .block
        case "javascript", "data", "file", "blob", nil:
            return .block
        default:
            return .external
        }
    }
}
