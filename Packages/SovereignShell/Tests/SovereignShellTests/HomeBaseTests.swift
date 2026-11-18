import Foundation
import Testing
@testable import SovereignShell

@Suite struct HomeBaseAddressTests {
    @Test func bareHostBecomesHttps() throws {
        let address = try #require(HomeBaseAddress("Home.Example.ts.net"))
        #expect(address.url.absoluteString == "https://home.example.ts.net/")
        #expect(address.resolving("api/home").absoluteString == "https://home.example.ts.net/api/home")
    }

    @Test func keepsAPathAndDropsQueryAndFragment() throws {
        let address = try #require(HomeBaseAddress("  https://example.ts.net/base?x=1#top \n"))
        #expect(address.url.absoluteString == "https://example.ts.net/base/")
        #expect(address.resolving("api/home").absoluteString == "https://example.ts.net/base/api/home")
    }

    @Test(arguments: ["http://home.example.ts.net", "ftp://home", "", "https://", "https://user:pw@home.example"])
    func refusesAnythingButPlainHttps(text: String) {
        #expect(HomeBaseAddress(text) == nil)
    }
}

@Suite struct HouseholdHomeTests {
    private func decode(_ json: String) throws -> HouseholdHome {
        try JSONDecoder().decode(HouseholdHome.self, from: Data(json.utf8))
    }

    @Test func member() throws {
        let home = try decode("""
        {"state":"member","caller":{"name":"Alex","login":"alex@example.com"},"canUnlockAdmin":true,
         "apps":[{"id":"family-dinner","name":"Dinner","icon":"🍽","url":"https://dinner.example.ts.net/"}]}
        """)
        #expect(home.state == .member)
        #expect(home.caller == .init(name: "Alex", login: "alex@example.com"))
        #expect(home.canUnlockAdmin)
        #expect(home.apps.map(\.id) == ["family-dinner"])
    }

    @Test func waitingWithoutApps() throws {
        let home = try decode(#"{"state":"waiting","caller":{"login":"kid@example.com"},"canUnlockAdmin":false,"apps":[],"candidateObserved":true}"#)
        #expect(home.state == .waiting)
        #expect(home.caller?.name == nil)
        #expect(home.candidateObserved == true)
    }

    @Test func unidentifiedHasNoCaller() throws {
        let home = try decode(#"{"state":"unidentified","caller":null,"canUnlockAdmin":false,"apps":[]}"#)
        #expect(home.state == .unidentified)
        #expect(home.caller == nil)
    }

    @Test func unknownStateAndExtraFieldsDontBreak() throws {
        let home = try decode(#"{"state":"something-new","caller":null,"canUnlockAdmin":false,"apps":[],"lifecycle":"active","future":{"x":1}}"#)
        #expect(home.state == .unknown("something-new"))
    }

    @Test func badAppEntriesAreDroppedNotFatal() throws {
        let home = try decode("""
        {"state":"member","caller":{"login":"a@b"},"canUnlockAdmin":false,"apps":[
          {"id":"ok","name":"OK","icon":"","url":"https://ok.example/"},
          {"id":"script","name":"Script","icon":"","url":"javascript:alert(1)"},
          {"id":"nourl","name":"No URL","icon":""},
          {"id":"relative","name":"Relative","icon":"","url":"/dinner/"}
        ]}
        """)
        #expect(home.apps.map(\.id) == ["ok"])
    }

    @Test func missingStateIsAnError() {
        #expect(throws: (any Error).self) { try decode(#"{"apps":[]}"#) }
    }
}

@Suite struct LinkRouteTests {
    let hosts: Set<String> = ["home.example.ts.net", "dinner.example.ts.net"]

    @Test(arguments: [
        ("https://home.example.ts.net/admin", LinkRoute.stay),
        ("https://DINNER.example.ts.net/tonight", .stay),
        ("https://advisories.example.org/x", .external),
        ("http://home.example.ts.net/", .external),
        ("mailto:someone@example.com", .external),
        ("tel:5551234", .external),
        ("about:blank", .stay),
        ("about:srcdoc", .block),
        ("javascript:alert(1)", .block),
        ("data:text/html,hi", .block),
        ("file:///etc/passwd", .block),
    ])
    func routes(link: String, expected: LinkRoute) throws {
        #expect(LinkRoute.of(try #require(URL(string: link)), householdHosts: hosts) == expected)
    }
}
