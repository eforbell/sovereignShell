import SovereignShell
import SwiftUI

@main
struct HomeBaseApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// The household address is the app's only setting. Without one, the person joins a household; with one,
/// they get its home. The spike screen reads the same key.
struct RootView: View {
    @AppStorage("homeBaseAddress") private var addressText = ""

    var body: some View {
        if let address = HomeBaseAddress(addressText) {
            HomeView(address: address) { addressText = "" }
                .id(address)
        } else {
            SetupView { addressText = $0.url.absoluteString }
        }
    }
}
