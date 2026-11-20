import Foundation
import Testing
@testable import SovereignShell

@Suite struct JoinCodeTests {
    @Test func theCodeIsTheJoinPage() throws {
        let address = try #require(HomeBaseAddress("smith-homebase.example.ts.net"))
        #expect(JoinCode.url(for: address).absoluteString == "https://smith-homebase.example.ts.net/join")
        #expect(JoinCode.address(from: JoinCode.url(for: address).absoluteString) == address)
    }

    @Test(arguments: [
        "https://smith-homebase.example.ts.net/join",
        "https://smith-homebase.example.ts.net/join/",
        "  HTTPS://Smith-HomeBase.example.ts.net/join?from=members#top \n",
    ])
    func readsAJoinCode(text: String) {
        #expect(JoinCode.address(from: text)?.typed == "smith-homebase.example.ts.net")
    }

    @Test func keepsAPortAndHomeBasesOwnPath() {
        #expect(JoinCode.address(from: "https://home.example.ts.net:8443/join")?.typed == "home.example.ts.net:8443")
        let based = JoinCode.address(from: "https://example.ts.net/base/join")
        #expect(based?.typed == "example.ts.net/base")
        #expect(based.map { JoinCode.url(for: $0).absoluteString } == "https://example.ts.net/base/join")
    }

    @Test(arguments: [
        "http://smith-homebase.example.ts.net/join",
        "https://smith-homebase.example.ts.net/",
        "https://smith-homebase.example.ts.net/admin",
        "https://smith-homebase.example.ts.net/joined",
        "https://user:pw@smith-homebase.example.ts.net/join",
        "sovereign-grant/1\nsmith-homebase.example.ts.net\nabcdefgh12",
        "smith-homebase.example.ts.net/join",
        "",
    ])
    func refusesAnythingElse(text: String) {
        #expect(JoinCode.address(from: text) == nil)
    }

    @Test func typedDropsTheSchemeAndSlash() throws {
        #expect(try #require(HomeBaseAddress("a.example.ts.net")).typed == "a.example.ts.net")
    }
}
