import Foundation
import Testing
@testable import SovereignShell

@Suite struct KnownHouseholdsTests {
    private func address(_ text: String) -> HomeBaseAddress { HomeBaseAddress(text)! }
    private var a: HomeBaseAddress { address("a-home.one.ts.net") }
    private var b: HomeBaseAddress { address("b-home.two.ts.net") }
    private var c: HomeBaseAddress { address("c-home.three.ts.net") }

    @Test func usingPutsTheAddressFirstOnce() {
        let known = KnownHouseholds().using(a).using(b).using(c).using(a)
        #expect(known.addresses == [a, c, b])
    }

    @Test func forgettingDropsOnlyThatAddress() {
        let known = KnownHouseholds().using(c).using(b).using(a).forgetting(b)
        #expect(known.addresses == [a, c])
        #expect(known.forgetting(b) == known)
    }

    @Test func keepsTheMostRecentUpToTheLimit() {
        let many = (0..<20).map { address("home-\($0).example.ts.net") }
        let known = many.reduce(KnownHouseholds()) { $0.using($1) }
        #expect(known.addresses.count == KnownHouseholds.limit)
        #expect(known.addresses.first == many.last)
        #expect(!known.addresses.contains(many[0]))
    }

    @Test func aNameStaysThroughSwitching() {
        let known = KnownHouseholds().using(a).using(b).naming(a, "Smiths").using(c).using(a)
        #expect(known.addresses == [a, c, b])
        #expect(known.entries.map(\.title) == ["Smiths", "c-home", "b-home"])
    }

    @Test func namingAnUnknownHouseholdChangesNothing() {
        let known = KnownHouseholds().using(a)
        #expect(known.naming(b, "Strangers") == known)
    }

    @Test func namesAreOneShortLine() {
        let known = KnownHouseholds().using(a).using(b).using(c)
            .naming(a, "  The\nSmiths ")
            .naming(b, String(repeating: "x", count: 80))
            .naming(c, "   ")
        #expect(known.entry(for: a)?.name == "The Smiths")
        #expect(known.entry(for: b)?.name?.count == 60)
        #expect(known.entry(for: c)?.name == nil)
        #expect(known.entry(for: c)?.title == "c-home")
        // Cut at 60, then trimmed: no trailing space.
        #expect(HouseholdHome.householdName(String(repeating: "x", count: 59) + " y") == String(repeating: "x", count: 59))
    }

    @Test func storedRoundTrips() {
        let known = KnownHouseholds().using(b).using(a).naming(a, "Smiths")
        #expect(KnownHouseholds(stored: known.stored) == known)
    }

    @Test func sameHouseholdHowEverItWasTyped() {
        let known = KnownHouseholds(stored: #"[{"address":"A-Home.One.ts.net"},{"address":"https://a-home.one.ts.net/","name":"x"}]"#)
        #expect(known.addresses == [a])
        #expect(known.entry(for: a)?.name == nil)
    }

    @Test(arguments: ["", "not json", "{}", #"[1, 2]"#, #"["a-home.one.ts.net"]"#])
    func unreadableStorageIsNone(stored: String) {
        #expect(KnownHouseholds(stored: stored).addresses.isEmpty)
    }

    @Test func entriesThatNoLongerReadDropOut() {
        let known = KnownHouseholds(stored: #"[{"address":"http://old.example.ts.net"},{"address":"b-home.two.ts.net","name":"Bs"},{"address":""}]"#)
        #expect(known.entries == [.init(address: b, name: "Bs")])
    }

    @Test func shortNameIsTheFirstLabel() {
        #expect(a.shortName == "a-home")
        #expect(address("localhost").shortName == "localhost")
        #expect(address("100.64.0.2").shortName == "100.64.0.2")
    }

    @Test func homeCarriesTheHouseholdName() throws {
        let named = try JSONDecoder().decode(HouseholdHome.self, from: Data(#"{"state":"waiting","household":" rehearsal "}"#.utf8))
        #expect(named.household == "rehearsal")
        let older = try JSONDecoder().decode(HouseholdHome.self, from: Data(#"{"state":"waiting"}"#.utf8))
        #expect(older.household == nil)
        let odd = try JSONDecoder().decode(HouseholdHome.self, from: Data(#"{"state":"waiting","household":42}"#.utf8))
        #expect(odd.household == nil)
    }
}
