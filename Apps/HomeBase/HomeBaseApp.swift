import SovereignShell
import SwiftUI

/// The certificate authorities household hosts must chain to: the operator's, bundled under TrustAnchors/
/// (Let's Encrypt's ISRG Root X1 and X2 by default, which Tailscale's certificates use).
let householdTrust = HouseholdTrust.bundled()

@main
struct HomeBaseApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// The current household's address, and the households this phone has joined. Without a current one, the
/// person joins a household; with one, they get its home and can switch to the others.
struct RootView: View {
    @AppStorage("homeBaseAddress") private var addressText = ""
    @AppStorage("knownHouseholds") private var knownText = ""

    private var current: HomeBaseAddress? { HomeBaseAddress(addressText) }

    /// The current household first. One joined before the list existed joins it here.
    private var known: KnownHouseholds {
        let stored = KnownHouseholds(stored: knownText)
        return current.map(stored.using) ?? stored
    }

    var body: some View {
        if let address = current {
            HomeView(address: address, households: Households(known: known, open: open, name: name, forget: forget))
                .id(address)
        } else {
            SetupView(save: open)
        }
    }

    /// Joins `address`, or switches to it.
    private func open(_ address: HomeBaseAddress) {
        knownText = known.using(address).stored
        addressText = address.url.absoluteString
    }

    private func name(_ address: HomeBaseAddress, _ name: String) {
        let named = known.naming(address, name)
        if named != known { knownText = named.stored }
    }

    /// Any but the current household: switch away from it first.
    private func forget(_ address: HomeBaseAddress) {
        guard address != current else { return }
        knownText = known.forgetting(address).stored
    }
}
