import SovereignShell
import SwiftUI

/// The household home: the launcher for a member, or where they are in onboarding. Everything shown comes
/// from `GET /api/home`, which Home Base filters for this person; the app decides nothing about access.
struct HomeView: View {
    let address: HomeBaseAddress
    let changeHousehold: () -> Void

    @State private var model: HomeModel
    /// Passkey checks for household pages in the app's web view (the native handoff).
    @State private var agent: HandoffAgent
    @State private var page: BrowserPage?
    @State private var safariPage: BrowserPage?
    @State private var confirmChange = false
    @Environment(\.scenePhase) private var scenePhase

    init(address: HomeBaseAddress, changeHousehold: @escaping () -> Void) {
        self.address = address
        self.changeHousehold = changeHousehold
        let client = HomeBaseClient(address: address, trust: householdTrust)
        _model = State(initialValue: HomeModel(client: client))
        let presenter = HandoffSheetPresenter()
        _agent = State(initialValue: HandoffAgent(
            homeBase: address,
            // The sheet returns to this app's bundle ID: Home Base's HOME_BASE_NATIVE_APP_SCHEME.
            callbackScheme: Bundle.main.bundleIdentifier ?? "",
            label: UIDevice.current.name,
            attest: SystemAppAttest(),
            transport: { host, path, body throws(HomeBaseError) in try await client.authPost(host: host, path: path, body: body) },
            sheet: { url, scheme throws(HandoffError) in try await presenter.present(url, callbackScheme: scheme) }
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding()
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Home Base")
            .toolbar { menu }
        }
        .task { await model.refresh() }
        .task(id: PollKey(interval: model.pollInterval, active: scenePhase == .active)) { await poll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .fullScreenCover(item: $page) { page in
            AppBrowser(page: page, householdHosts: model.householdHosts(homeBase: address), homeBase: address) { id, host throws(HandoffError) in
                try await agent.handoff(id: id, host: host)
            }
        }
        .sheet(item: $safariPage) { page in SafariView(url: page.url).ignoresSafeArea() }
        .confirmationDialog("Change household?", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("Change household", role: .destructive, action: changeHousehold)
        } message: {
            Text("This phone forgets \(address.host). Your membership in Home Base doesn't change.")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Checking your household…")
                .frame(maxWidth: .infinity, minHeight: 300)
        case .failed(let error):
            failure(error)
        case .loaded(let home):
            loaded(home)
        }
    }

    @ViewBuilder private func loaded(_ home: HouseholdHome) -> some View {
        switch home.state {
        case .member:
            launcher(home)
        case .waiting:
            Notice(
                symbol: "person.badge.clock",
                title: "Welcome to Home Base",
                message: "Your household administrator needs to add you before your apps appear.",
                detail: home.candidateObserved == true
                    ? "Your visit is visible in Admin → Members. Ask your administrator to find your account there and add you."
                    : "Ask your administrator to look for your account in Members. If it isn't listed, check that this phone is connected to your household's tailnet, then try again.",
                caller: home.caller
            ) {
                Label("Checking for access automatically", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                retry
            }
        case .unidentified:
            Notice(
                symbol: "network.slash",
                title: "Connect to your household",
                message: "Home Base couldn't verify your tailnet account.",
                detail: "Open the Tailscale app and make sure this phone is connected to your household's tailnet, then try again.",
                caller: nil
            ) { retry }
        case .disabled:
            Notice(
                symbol: "lock.fill",
                title: "Access unavailable",
                message: "Your household account is disabled.",
                detail: "Contact your household administrator if you think this is a mistake.",
                caller: home.caller
            ) { EmptyView() }
        case .unavailable:
            Notice(
                symbol: "exclamationmark.triangle",
                title: "We couldn't check your access",
                message: "Home Base can't check your household membership right now.",
                detail: "Try again in a moment. If this continues, ask your household administrator to check the connection.",
                caller: home.caller
            ) {
                retry
                if home.canUnlockAdmin { adminButton }
            }
        case .setup:
            Notice(
                symbol: "wrench.and.screwdriver",
                title: "Your household is being set up",
                message: "Your household administrator needs to finish setup before apps are available.",
                detail: "The administrator finishes setup on Admin.",
                caller: home.caller
            ) { retry; adminButton }
        case .recovery:
            Notice(
                symbol: "cross.case",
                title: "Your household is in recovery",
                message: "Apps will appear here after your administrator finishes recovery.",
                detail: "The administrator finishes recovery on Admin.",
                caller: home.caller
            ) { retry; adminButton }
        case .administrator:
            Notice(
                symbol: "key.fill",
                title: "Administration is unlocked",
                message: "Continue in Admin.",
                detail: nil,
                caller: home.caller
            ) { adminButton; webButton }
        case .legacy, .unknown:
            Notice(
                symbol: "house",
                title: "Open Home Base",
                message: "This Home Base doesn't offer the app launcher yet.",
                detail: "Its web dashboard still works.",
                caller: home.caller
            ) { webButton }
        }
    }

    private func launcher(_ home: HouseholdHome) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let caller = home.caller {
                Text("Connected as **\(caller.name ?? caller.login)**")
                    .foregroundStyle(.secondary)
            }
            if home.apps.isEmpty {
                Notice(
                    symbol: "square.dashed",
                    title: "No apps available yet",
                    message: "You're a member, but no apps are available to you yet.",
                    detail: "Ask your household administrator to check your app access.",
                    caller: nil
                ) { retry }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(home.apps) { app in
                        Button {
                            page = BrowserPage(title: app.name, url: app.url, kind: .inApp)
                        } label: {
                            AppTile(app: app)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(app.name)")
                    }
                }
            }
            if home.canUnlockAdmin {
                adminButton.padding(.top, 8)
            }
        }
    }

    private func failure(_ error: HomeBaseError) -> some View {
        let (title, message): (String, String) = switch error {
        case .unreachable:
            ("Can't reach your household", "Make sure this phone is connected to your household's tailnet in the Tailscale app, then try again. If it still fails, check the address with your administrator.")
        case .untrusted:
            ("Can't verify your household's certificate", "Home Base didn't present a certificate from the authorities this app trusts for your household, so the app didn't use the connection. If your household changed its certificate authority, this app needs an update.")
        case .http(let status):
            ("Home Base had a problem", "It answered with an error (\(status)). Try again in a moment.")
        case .unreadable:
            ("Home Base sent an answer this app can't read", "Try again. If it keeps happening, this app may need an update.")
        }
        return Notice(symbol: "wifi.exclamationmark", title: title, message: message, detail: address.host, caller: nil) {
            retry
            Button("Change household") { confirmChange = true }
        }
    }

    // MARK: Actions

    private var retry: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            if model.isRefreshing { ProgressView() } else { Text("Check again") }
        }
        .buttonStyle(.bordered)
        .disabled(model.isRefreshing)
    }

    /// Admin opens in the app: unlocking it is a check, which the app's sheet runs. Registering a passkey
    /// stays in a browser, from the menu.
    private var adminButton: some View {
        Button("Open Admin", systemImage: "key") {
            page = BrowserPage(title: "Admin", url: address.resolving("admin"), kind: .inApp)
        }
        .buttonStyle(.bordered)
    }

    private var webButton: some View {
        Button("Open Home Base", systemImage: "safari") {
            page = BrowserPage(title: "Home Base", url: address.url, kind: .inApp)
        }
        .buttonStyle(.borderedProminent)
    }

    private var menu: some View {
        Menu {
            Button("Open Home Base on the web", systemImage: "globe") {
                page = BrowserPage(title: "Home Base", url: address.url, kind: .inApp)
            }
            // Registering a passkey, and activation, run in a browser: the app's web view can't create one.
            Button("Open Admin in Safari", systemImage: "safari") {
                safariPage = BrowserPage(title: "Admin", url: address.resolving("admin"), kind: .safari)
            }
            Divider()
            Button("Change household…", systemImage: "arrow.left.arrow.right") { confirmChange = true }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Polling

    private struct PollKey: Hashable {
        let interval: Duration?
        let active: Bool
    }

    /// Re-checks on a timer only while someone waits for admission and the app is on screen.
    private func poll() async {
        guard let interval = model.pollInterval, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await model.refresh()
        }
    }
}

/// One app in the launcher: its emoji (or initial) and name, big enough for small hands.
private struct AppTile: View {
    let app: HouseholdHome.App

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if app.icon.isEmpty {
                    Text(String(app.name.prefix(1)).uppercased())
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text(app.icon)
                        .font(.system(size: 48))
                        .frame(width: 64, height: 64)
                }
            }
            .accessibilityHidden(true)
            Text(app.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A full-width message card for every non-launcher state.
private struct Notice<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    let detail: String?
    let caller: HouseholdHome.Caller?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            if let caller {
                Text("Connected as **\(caller.name ?? caller.login)**")
                    .foregroundStyle(.secondary)
            }
            Text(message)
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) { actions() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
