import Foundation

/// Where a household's Home Base lives. Entered at first launch (typed or from a join code), never compiled in.
public struct HomeBaseAddress: Hashable, Codable, Sendable {
    public let url: URL

    /// Accepts `home.example.ts.net`, `https://home.example.ts.net` or the same with a path.
    /// Only https: tailnet hostnames carry real certificates, and App Transport Security expects them.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil
        else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.query = nil
        parts.fragment = nil
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { return nil }
        self.url = url
    }

    public var host: String { url.host() ?? "" }

    /// The domain household trust covers: Home Base's host without its first label (the tailnet's domain,
    /// as `smith-homebase.example-tailnet.ts.net` gives `example-tailnet.ts.net`), where every household
    /// service has its hostname. Taken from the address alone, so it never depends on what Home Base answers.
    public var trustDomain: String {
        let labels = host.split(separator: ".")
        return labels.count >= 3 ? labels.dropFirst().joined(separator: ".") : host
    }

    /// Whether `host` is held to household trust: Home Base's own host, or any host under `trustDomain`.
    public func trustCovers(_ host: String) -> Bool {
        let host = host.lowercased()
        let domain = trustDomain
        return host == self.host || host == domain || host.hasSuffix("." + domain)
    }

    /// A path under Home Base, e.g. `api/home` or `admin`.
    public func resolving(_ path: String) -> URL {
        url.appending(path: path)
    }
}

/// What `GET /api/home` says about the caller. Home Base filters it on the server; the app only renders it.
public struct HouseholdHome: Decodable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case member, waiting, unidentified, disabled, unavailable, setup, recovery, administrator, legacy
        /// A state this build doesn't know yet: show a neutral message and the web dashboard.
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "member": self = .member
            case "waiting": self = .waiting
            case "unidentified": self = .unidentified
            case "disabled": self = .disabled
            case "unavailable": self = .unavailable
            case "setup": self = .setup
            case "recovery": self = .recovery
            case "administrator": self = .administrator
            case "legacy": self = .legacy
            default: self = .unknown(raw)
            }
        }
    }

    public struct Caller: Decodable, Equatable, Sendable {
        public let name: String?
        public let login: String
    }

    public struct App: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let icon: String
        public let url: URL
    }

    public let state: State
    public let caller: Caller?
    public let canUnlockAdmin: Bool
    public let candidateObserved: Bool?
    public let apps: [App]

    private enum Keys: String, CodingKey { case state, caller, canUnlockAdmin, candidateObserved, apps }

    /// Loose on purpose: a field Home Base adds later never breaks an installed app, and one bad app entry
    /// drops that entry rather than the whole launcher. Only http(s) app links are kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = State(try c.decode(String.self, forKey: .state))
        caller = try? c.decodeIfPresent(Caller.self, forKey: .caller)
        canUnlockAdmin = (try? c.decodeIfPresent(Bool.self, forKey: .canUnlockAdmin)) ?? false
        candidateObserved = try? c.decodeIfPresent(Bool.self, forKey: .candidateObserved)
        let raw = (try? c.decodeIfPresent([LossyApp].self, forKey: .apps)) ?? []
        apps = raw.compactMap(\.app)
    }

    private struct LossyApp: Decodable {
        let app: App?
        init(from decoder: Decoder) throws {
            guard let candidate = try? App(from: decoder),
                  let scheme = candidate.url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  candidate.url.host() != nil
            else { app = nil; return }
            app = candidate
        }
    }
}

public enum HomeBaseError: Error, Equatable, Sendable {
    /// No answer at all: often the phone isn't on the tailnet, or the address is wrong.
    case unreachable(String)
    /// The household host's certificate doesn't chain to the pinned authorities (HouseholdTrust).
    case untrusted
    case http(Int)
    case unreadable
}

/// Talks to one household's Home Base. Requests go through the phone's tailnet connection, so Home Base
/// identifies the member exactly as it does for Safari; there's no app-side credential.
public struct HomeBaseClient: Sendable {
    public let address: HomeBaseAddress
    private let session: URLSession
    private let trustDelegate: HouseholdTrustDelegate?

    /// Home Base's hostname is strict (sovereignAuth wire contract §4.1): it refuses any request without
    /// fetch metadata, which browsers send and URLSession doesn't. This app is Home Base's own client, so it
    /// says what Home Base's own pages say when they call its API. The guard isolates browser sites from one
    /// another; it isn't authentication, and no web page can make these native requests.
    static let firstPartyFetchMetadata = [
        "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Dest": "empty",
    ]

    /// A client whose requests trust only the household's pinned authorities (the app's).
    public init(address: HomeBaseAddress, trust: HouseholdTrust) {
        let delegate = HouseholdTrustDelegate(trust: trust)
        self.address = address
        self.trustDelegate = delegate
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    /// A client on a session of the caller's (tests).
    public init(address: HomeBaseAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
        self.trustDelegate = nil
    }

    /// The error for a request that got no answer: untrusted when the household trust refused its host.
    func failure(_ error: any Error, host: String) -> HomeBaseError {
        if let trustDelegate, trustDelegate.refused(host) { return .untrusted }
        return .unreachable(error.localizedDescription)
    }

    public func home() async throws(HomeBaseError) -> HouseholdHome {
        var request = URLRequest(url: address.resolving("api/home"))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in Self.firstPartyFetchMetadata { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw failure(error, host: address.host)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        guard http.statusCode == 200 else { throw .http(http.statusCode) }
        do {
            return try JSONDecoder().decode(HouseholdHome.self, from: data)
        } catch {
            throw .unreadable
        }
    }
}
