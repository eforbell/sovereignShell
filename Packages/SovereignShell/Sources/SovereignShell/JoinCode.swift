import Foundation

/// A household's join code: the address of its Home Base's join page, `https://<host>/join`. Home Base shows
/// it on that page (Admin → Members links there), and the app shows it under Households → Invite someone.
/// Scanned on the Join screen, it fills in the household's address for the person to check and continue; the
/// iPhone's Camera opens the page itself. It's only an address: joining still takes the tailnet and the
/// administrator's approval.
public enum JoinCode {
    /// The join page of `address`: what the code holds.
    public static func url(for address: HomeBaseAddress) -> URL {
        address.resolving("join")
    }

    /// The household a scanned join code is for, or nil when `text` isn't one: an https URL whose path ends
    /// in `/join` (under Home Base's own path, if it has one). Its query and fragment are ignored.
    public static func address(from text: String) -> HomeBaseAddress? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil
        else { return nil }
        let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        guard path.hasSuffix("/join") else { return nil }
        var base = URLComponents()
        base.scheme = "https"
        base.host = host
        base.port = parts.port
        base.path = String(path.dropLast("join".count))
        return base.url.flatMap { HomeBaseAddress($0.absoluteString) }
    }
}

extension HomeBaseAddress {
    /// The address as a person types it: no `https://`, no trailing slash.
    public var typed: String {
        var text = url.absoluteString
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
