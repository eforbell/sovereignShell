import Foundation
import Testing
@testable import SovereignShell

/// Hands out canned answers in order and counts calls. Each call can be held until released.
private actor Script {
    private var answers: [Result<HouseholdHome, HomeBaseError>]
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private let holds: Bool

    init(_ answers: [Result<HouseholdHome, HomeBaseError>], holds: Bool = false) {
        self.answers = answers
        self.holds = holds
    }

    func next() async throws(HomeBaseError) -> HouseholdHome {
        calls += 1
        if holds { await withCheckedContinuation { gate = $0 } }
        return try answers.removeFirst().get()
    }

    func release() { gate?.resume(); gate = nil }
    var waiting: Bool { gate != nil }
}

private func home(_ json: String) -> HouseholdHome {
    try! JSONDecoder().decode(HouseholdHome.self, from: Data(json.utf8))
}

private let member = home(#"{"state":"member","caller":{"login":"a@b"},"canUnlockAdmin":false,"apps":[{"id":"dinner","name":"Dinner","icon":"🍽","url":"https://Dinner.example.ts.net/tonight"},{"id":"pulse","name":"Pulse","icon":"","url":"https://pulse.example.ts.net/"}]}"#)
private let waiting = home(#"{"state":"waiting","caller":{"login":"a@b"},"canUnlockAdmin":false,"apps":[]}"#)

@MainActor
@Suite struct HomeModelTests {
    @Test func startsLoadingThenShowsTheAnswer() async {
        let script = Script([.success(member)])
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        #expect(model.phase == .loading)
        await model.refresh()
        #expect(model.phase == .loaded(member))
        #expect(!model.isRefreshing)
    }

    @Test func aFailureReplacesTheAnswerAndARetryRecovers() async {
        let script = Script([.success(member), .failure(.unreachable("offline")), .success(member)])
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        await model.refresh()
        await model.refresh()
        #expect(model.phase == .failed(.unreachable("offline")))
        await model.refresh()
        #expect(model.phase == .loaded(member))
    }

    @Test func onlyWaitingIsPolled() async {
        let script = Script([.success(waiting), .success(member), .failure(.http(503))])
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        #expect(model.pollInterval == nil)
        await model.refresh()
        #expect(model.pollInterval == .seconds(10))
        await model.refresh()
        #expect(model.pollInterval == nil)
        await model.refresh()
        #expect(model.pollInterval == nil)
    }

    @Test func aFailedCheckWhileWaitingKeepsPolling() async {
        let script = Script([.success(waiting), .failure(.unreachable("timed out")), .failure(.http(503)), .success(member)])
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        await model.refresh()
        await model.refresh()
        #expect(model.phase == .failed(.unreachable("timed out")))
        #expect(model.pollInterval == .seconds(10))
        await model.refresh()
        #expect(model.pollInterval == .seconds(10))
        await model.refresh()
        #expect(model.phase == .loaded(member))
        #expect(model.pollInterval == nil)
    }

    @Test func aRefreshDuringARefreshSharesIt() async {
        let script = Script([.success(member)], holds: true)
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        let first = Task { await model.refresh() }
        while !(await script.waiting) { await Task.yield() }
        #expect(model.isRefreshing)
        let second = Task { await model.refresh() }
        await Task.yield()
        #expect(await script.calls == 1)
        await script.release()
        await first.value
        await second.value
        #expect(await script.calls == 1)
        #expect(model.phase == .loaded(member))
        #expect(!model.isRefreshing)
    }

    @Test func cancellingTheCallerDoesntCancelTheCheck() async {
        let script = Script([.success(member), .success(member)], holds: true)
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        let poll = Task { await model.refresh() }
        while !(await script.waiting) { await Task.yield() }
        poll.cancel()  // the app left the screen mid-check
        await script.release()
        await poll.value
        #expect(model.phase == .loaded(member))
        #expect(!model.isRefreshing)
        // The next refresh (the app coming back) makes its own request.
        let again = Task { await model.refresh() }
        while !(await script.waiting) { await Task.yield() }
        await script.release()
        await again.value
        #expect(await script.calls == 2)
    }

    @Test func householdHostsAreHomeBaseAndTheMembersApps() async throws {
        let address = try #require(HomeBaseAddress("home.example.ts.net"))
        let script = Script([.success(member)])
        let model = HomeModel(fetch: { () async throws(HomeBaseError) -> HouseholdHome in try await script.next() })
        #expect(model.householdHosts(homeBase: address) == ["home.example.ts.net"])
        await model.refresh()
        #expect(model.householdHosts(homeBase: address) == ["home.example.ts.net", "dinner.example.ts.net", "pulse.example.ts.net"])
    }
}
