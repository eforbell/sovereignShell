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

@Suite struct TrustScopeTests {
    @Test func theTailnetDomainComesFromHomeBasesAddress() throws {
        let address = try #require(HomeBaseAddress("smith-homebase.example-tailnet.ts.net"))
        #expect(address.trustDomain == "example-tailnet.ts.net")
        #expect(address.trustCovers("smith-homebase.example-tailnet.ts.net"))
        #expect(address.trustCovers("SMITH-PULSE.example-tailnet.ts.net"), "every household service, whatever /api/home says")
        #expect(address.trustCovers("example-tailnet.ts.net"))
        #expect(!address.trustCovers("example-tailnet.ts.net.attacker.example"))
        #expect(!address.trustCovers("notexample-tailnet.ts.net"))
        #expect(!address.trustCovers("www.apple.com"))
        let short = try #require(HomeBaseAddress("homebase.lan"))
        #expect(short.trustDomain == "homebase.lan")
        #expect(short.trustCovers("homebase.lan") && !short.trustCovers("other.lan"))
    }
}


@Suite struct PasskeyInviteTests {
    private let address = HomeBaseAddress("smith-homebase.example-tailnet.ts.net")!
    private let code = "oIyLcsPf5vbG94TsrgvH4g"
    private func home(_ invite: String) throws -> HouseholdHome {
        try JSONDecoder().decode(HouseholdHome.self, from: Data(#"{"state":"member","caller":{"login":"kid@example.com"},"canUnlockAdmin":false,"apps":[]\#(invite)}"#.utf8))
    }

    @Test func decodesTheInviteAndItsExpiry() throws {
        #expect(try home(#","passkeyInvite":{"expiresAt":"2026-11-19T20:36:00.000Z"}"#).passkeyInvite?.expiresAt == Date(timeIntervalSince1970: 1_795_120_560))
        #expect(try home(#","passkeyInvite":{"expiresAt":"2026-11-19T20:36:00Z"}"#).passkeyInvite?.expiresAt == Date(timeIntervalSince1970: 1_795_120_560))
        #expect(try home("").passkeyInvite == nil)
        #expect(try home(#","passkeyInvite":null"#).passkeyInvite == nil)
        // An expiry that doesn't read never hides the invitation, and never breaks the launcher.
        for odd in [#","passkeyInvite":{}"#, #","passkeyInvite":{"expiresAt":42}"#, #","passkeyInvite":{"expiresAt":"soon"}"#] {
            let invite = try home(odd).passkeyInvite
            #expect(invite != nil && invite?.expiresAt == nil, "\(odd)")
        }
    }

    @Test func scannedCodeForThisHousehold() {
        let expected: Result<EnrollmentCode, EnrollmentCode.Problem> = .success(EnrollmentCode(value: code))
        #expect(EnrollmentCode.parse("sovereign-grant/1\nsmith-homebase.example-tailnet.ts.net\n\(code)", from: .scanned, for: address) == expected)
        #expect(EnrollmentCode.parse("sovereign-grant/1\r\nSMITH-HOMEBASE.example-tailnet.ts.net.\r\n\(code)\r\n", from: .scanned, for: address) == expected, "CRLF, case, a trailing dot")
        #expect(EnrollmentCode.parse("sovereign-grant/1\nsmith-homebase.example-tailnet.ts.net\n\(code)", from: .pasted, for: address) == expected, "the whole card text, pasted")
    }

    @Test func scannedCodeForAnotherHousehold() {
        #expect(EnrollmentCode.parse("sovereign-grant/1\njones-homebase.example-tailnet.ts.net\n\(code)", from: .scanned, for: address) == .failure(.otherHousehold("jones-homebase.example-tailnet.ts.net")))
        #expect(EnrollmentCode.parse("sovereign-grant/1\ncall 555-0100 now!\n\(code)", from: .scanned, for: address) == .failure(.otherHousehold(nil)), "nothing that isn't a hostname is shown")
    }

    @Test func pastedCodeAlone() {
        #expect(EnrollmentCode.parse("  \(code) \n", from: .pasted, for: address) == .success(EnrollmentCode(value: code)))
        #expect(EnrollmentCode.parse(code, from: .scanned, for: address) == .failure(.unreadable), "a QR code must name its household")
    }

    @Test func codeLengths() {
        #expect(EnrollmentCode.parse(String(repeating: "a", count: 8), from: .pasted, for: address) == .success(EnrollmentCode(value: String(repeating: "a", count: 8))))
        #expect(EnrollmentCode.parse(String(repeating: "a", count: 64), from: .pasted, for: address) == .success(EnrollmentCode(value: String(repeating: "a", count: 64))))
        #expect(EnrollmentCode.parse(String(repeating: "a", count: 7), from: .pasted, for: address) == .failure(.unreadable))
        #expect(EnrollmentCode.parse(String(repeating: "a", count: 65), from: .pasted, for: address) == .failure(.unreadable))
    }

    @Test(arguments: ["", "short", "has spaces in it", "https://example.com/?grant=abc", "sovereign-grant/2\nsmith-homebase.example-tailnet.ts.net\noIyLcsPf5vbG94TsrgvH4g", "sovereign-grant/1\nsmith-homebase.example-tailnet.ts.net\n<script>", "a\nb", "caf\u{e9}caf\u{e9}caf\u{e9}", "\u{FF41}\u{FF42}\u{FF43}\u{FF44}\u{FF45}\u{FF46}\u{FF47}\u{FF48}", "sovereign-grant/1\n\noIyLcsPf5vbG94TsrgvH4g"])
    func notACode(_ text: String) {
        #expect(EnrollmentCode.parse(text, from: .pasted, for: address) == .failure(.unreadable))
    }

    @Test func opensAdminWithTheCodeInTheFragment() {
        let url = address.addPasskey(code: EnrollmentCode(value: code))
        #expect(url.absoluteString == "https://smith-homebase.example-tailnet.ts.net/admin#grant=oIyLcsPf5vbG94TsrgvH4g")
    }
}
