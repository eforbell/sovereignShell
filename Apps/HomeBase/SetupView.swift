import SovereignShell
import SwiftUI

/// First launch: which household is this phone joining? The address is all the app needs; Home Base
/// recognizes the person from the phone's tailnet connection, and admission stays the administrator's call.
struct SetupView: View {
    let save: (HomeBaseAddress) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var address: HomeBaseAddress? { HomeBaseAddress(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Join your household")
                            .font(.title.bold())
                        Text("Enter your household's Home Base address. Your household administrator can tell you what it is.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
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
                } header: {
                    Text("Home Base address")
                } footer: {
                    if !text.isEmpty && address == nil {
                        Text("Enter an https address, like home.example.ts.net.").foregroundStyle(.red)
                    } else {
                        Text("This phone needs to be connected to your household's tailnet in the Tailscale app first.")
                    }
                }

                Section {
                    Button("Continue", action: submit)
                        .frame(maxWidth: .infinity)
                        .disabled(address == nil)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        if let address { save(address) }
    }
}
