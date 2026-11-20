import SovereignShell
import SwiftUI
import VisionKit

/// First launch: which household is this phone joining? The address is all the app needs; Home Base
/// recognizes the person from the phone's tailnet connection, and admission stays the administrator's call.
struct SetupView: View {
    let save: (HomeBaseAddress) -> Void

    var body: some View {
        NavigationStack { JoinForm(welcome: true, save: save) }
    }
}

/// The address form: on first launch with a welcome, or from Households to join another. The household's
/// join code (`JoinCode`), scanned, fills in the address; the person checks it and continues.
struct JoinForm: View {
    let welcome: Bool
    let save: (HomeBaseAddress) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var scanning = false
    /// The address came from a join code: the footer asks to check it.
    @State private var scanned = false
    @State private var scannedText = ""
    @State private var problem: String?
    @State private var cameraDenied = false
    @Environment(\.openURL) private var openURL

    private var address: HomeBaseAddress? { HomeBaseAddress(text) }

    var body: some View {
        Form {
            if welcome {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Join your household")
                            .font(.title.bold())
                        Text("Scan your household's join code, or enter its Home Base address. Your household administrator can show you either.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
            }

            if DataScannerViewController.isSupported {
                Section {
                    Button("Scan a join code", systemImage: "qrcode.viewfinder") { Task { await scan() } }
                    if cameraDenied {
                        Button("Allow the camera in Settings") {
                            if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                        }
                    }
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("The code is on Admin → Members → Show the join code, or on a member's phone under Households → Invite someone.")
                    }
                }
            }

            Section {
                TextField("home.example.ts.net", text: $text)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit(submit)
                    .onChange(of: text) { _, now in
                        if scanned && now != scannedText { scanned = false }
                    }
            } header: {
                Text("Home Base address")
            } footer: {
                if !text.isEmpty && address == nil {
                    Text("Enter an https address, like home.example.ts.net.").foregroundStyle(.red)
                } else if scanned {
                    Text("From the join code. Check it's your household's, then Continue. This phone needs to be connected to the household's tailnet in the Tailscale app.")
                } else {
                    Text("This phone needs to be connected to the household's tailnet in the Tailscale app first.")
                }
            }

            Section {
                Button("Continue", action: submit)
                    .frame(maxWidth: .infinity)
                    .disabled(address == nil)
            }
        }
        .navigationTitle(welcome ? "" : "Join a household")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                CodeScanner(accept: accept) { failure in
                    scanning = false
                    problem = "\(failure) Type the address instead."
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the join code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }
                    }
                }
            }
        }
    }

    private func scan() async {
        problem = nil
        focused = false
        switch await CameraAccess.ask() {
        case .ready:
            cameraDenied = false
            scanning = true
        case .denied:
            cameraDenied = true
            problem = "Home Base can't use the camera. Allow it in Settings, or type the address."
        case .unavailable(let reason):
            problem = "\(reason) Type the address instead."
        }
    }

    /// A join code fills in the address (not saved: the person checks it and continues). Other codes in view
    /// are passed over, and scanning goes on.
    private func accept(_ code: String) -> Bool {
        guard let address = JoinCode.address(from: code) else { return false }
        scannedText = address.typed
        text = scannedText
        scanned = true
        problem = nil
        scanning = false
        return true
    }

    private func submit() {
        if let address { save(address) }
    }
}
