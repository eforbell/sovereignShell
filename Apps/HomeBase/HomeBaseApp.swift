import SwiftUI

@main
struct HomeBaseApp: App {
    var body: some Scene {
        WindowGroup {
            // Phase 0: the spike screen. The native launcher and onboarding replace it in phase 2 (docs/plan.md).
            SpikeView()
        }
    }
}
