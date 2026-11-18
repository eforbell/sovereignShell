import Foundation
import Observation

/// The launcher's view of one household: the last answer from `GET /api/home`, or why there isn't one.
@MainActor
@Observable
public final class HomeModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded(HouseholdHome)
        case failed(HomeBaseError)
    }

    public typealias Fetch = @Sendable () async throws(HomeBaseError) -> HouseholdHome

    public private(set) var phase: Phase = .loading
    /// True while a request is out, including a refresh behind an answer already on screen.
    public private(set) var isRefreshing = false

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public convenience init(client: HomeBaseClient) {
        self.init(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await client.home() })
    }

    /// Asks Home Base again. A call made while one is out is dropped: the answer on its way is just as new.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            phase = .loaded(try await fetch())
        } catch {
            phase = .failed(error)
        }
    }

    /// How often to ask again on its own, or nil to wait for the person. Like Home Base's web page, only
    /// someone waiting to be admitted is re-checked, so admission shows up without a tap.
    public var pollInterval: Duration? {
        if case .loaded(let home) = phase, home.state == .waiting { return .seconds(10) }
        return nil
    }

    /// Every host that stays inside the app: Home Base itself and each app this member may open.
    public func householdHosts(homeBase address: HomeBaseAddress) -> Set<String> {
        var hosts: Set<String> = [address.host]
        if case .loaded(let home) = phase {
            for app in home.apps { if let host = app.url.host()?.lowercased() { hosts.insert(host) } }
        }
        return hosts
    }
}
