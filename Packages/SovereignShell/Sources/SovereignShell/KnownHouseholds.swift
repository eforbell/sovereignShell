import Foundation

/// The households this phone has joined, most recently used first, so the app can switch between them
/// without typing an address again. Each keeps the name its Home Base gives (`household` in `/api/home`)
/// for the list. Read back through `HomeBaseAddress`, so an entry that no longer reads just drops out.
/// Each household's app registration is kept by its host (`AppInstanceStore`), so switching back needs no
/// new registration.
public struct KnownHouseholds: Equatable, Sendable {
    /// Enough for an operator's rehearsal and real households; the oldest go first.
    public static let limit = 12

    public struct Entry: Equatable, Sendable {
        public let address: HomeBaseAddress
        /// What Home Base calls the household, once it has answered.
        public let name: String?

        public init(address: HomeBaseAddress, name: String? = nil) {
            self.address = address
            self.name = name
        }

        /// For lists: the household's name, else the host's first label.
        public var title: String { name ?? address.shortName }
    }

    /// Most recently used first; one per address.
    public let entries: [Entry]

    public var addresses: [HomeBaseAddress] { entries.map(\.address) }

    public init(_ entries: [Entry] = []) {
        var seen = Set<HomeBaseAddress>()
        self.entries = Array(entries.filter { seen.insert($0.address).inserted }.prefix(Self.limit))
    }

    private struct Stored: Codable {
        let address: String
        let name: String?
    }

    /// From `stored`: what `stored` wrote. Anything else reads as none.
    public init(stored: String) {
        let rows = (try? JSONDecoder().decode([Stored].self, from: Data(stored.utf8))) ?? []
        self.init(rows.compactMap { row in
            HomeBaseAddress(row.address).map { Entry(address: $0, name: HouseholdHome.householdName(row.name)) }
        })
    }

    /// A JSON array of `{address, name}`.
    public var stored: String {
        let rows = entries.map { Stored(address: $0.address.url.absoluteString, name: $0.name) }
        let data = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public func entry(for address: HomeBaseAddress) -> Entry? {
        entries.first { $0.address == address }
    }

    /// With `address` first, keeping its name: just joined, or switched to.
    public func using(_ address: HomeBaseAddress) -> KnownHouseholds {
        KnownHouseholds([entry(for: address) ?? Entry(address: address)] + entries)
    }

    /// With `address` named `name`, where it stands; unchanged if the phone doesn't know `address`.
    public func naming(_ address: HomeBaseAddress, _ name: String) -> KnownHouseholds {
        KnownHouseholds(entries.map { $0.address == address ? Entry(address: address, name: HouseholdHome.householdName(name)) : $0 })
    }

    /// Without `address`. The phone forgets it; the membership in that Home Base doesn't change.
    public func forgetting(_ address: HomeBaseAddress) -> KnownHouseholds {
        KnownHouseholds(entries.filter { $0.address != address })
    }
}

extension HomeBaseAddress {
    /// A short name for lists: the host's first label (`smith-homebase` for `smith-homebase.example.ts.net`).
    public var shortName: String {
        host.split(separator: ".").first.map(String.init) ?? host
    }
}
