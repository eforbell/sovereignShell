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
    private var inFlight: Task<Void, Never>?
    /// The last answer said this person waits for admission. A failed check doesn't change that, so polling
    /// keeps going through a timeout or a 503 and admission still shows up without a tap.
    private var waitingForAdmission = false

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public convenience init(client: HomeBaseClient) {
        self.init(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await client.home() })
    }

    /// Asks Home Base again. A call made while one is out waits for that one: its answer is just as new.
    /// The request belongs to the model, not the caller, so a caller that goes away (a poll cancelled as
    /// the app leaves the screen) neither cancels it nor records a failure for it.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        isRefreshing = true
        let fetch = self.fetch
        let task = Task { @MainActor in
            let next: Phase
            do throws(HomeBaseError) {
                next = .loaded(try await fetch())
            } catch {
                next = .failed(error)
            }
            if case .loaded(let home) = next { self.waitingForAdmission = home.state == .waiting }
            self.phase = next
            self.inFlight = nil
            self.isRefreshing = false
        }
        inFlight = task
        await task.value
    }

    /// How often to ask again on its own, or nil to wait for the person. Like Home Base's web page, only
    /// someone waiting to be admitted is re-checked, so admission shows up without a tap.
    public var pollInterval: Duration? {
        waitingForAdmission ? .seconds(10) : nil
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
