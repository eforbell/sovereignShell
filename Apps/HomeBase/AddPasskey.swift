import SovereignShell
import SwiftUI
import VisionKit

/// "Add a passkey": the administrator invited this member to add their first passkey (`passkeyInvite` in
/// `/api/home`) and shows them its enrollment code on the Members card. The member scans its QR code here,
/// or pastes the code, and the app opens Admin's Passkeys panel with the code filled in. The panel runs the
/// passkey sheet through the handoff. The code is never taken from a link (sovereignAuth
/// docs/native-handoff.md, Part 3, "The grant keeps its code").
struct AddPasskeyCard: View {
    let address: HomeBaseAddress
    let invite: HouseholdHome.PasskeyInvite
    /// Opens the Passkeys panel in the app's web view.
    let open: (URL) -> Void

    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add a passkey", systemImage: "person.badge.key")
                .font(.headline)
            Text("Your administrator invited you to add a passkey. Scan the code they show you on the Members card, or paste it if they sent it to you.")
            if let expiresAt = invite.expiresAt {
                Text("The invitation lasts until \(expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Scan code", systemImage: "qrcode.viewfinder") { scanning = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!CodeScanner.isAvailable)
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in use(text) }
                }
                .labelStyle(.titleAndIcon)
            }
            if !CodeScanner.isAvailable {
                Text("Scanning needs the camera, which isn't available here. Paste the code instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(isPresented: $scanning) {
            NavigationStack {
                CodeScanner { text in
                    scanning = false
                    use(text)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }
                    }
                }
            }
        }
    }

    private func use(_ text: String) {
        switch EnrollmentCode.parse(text, for: address) {
        case .success(let code):
            problem = nil
            open(address.addPasskey(code: code))
        case .failure(.otherHousehold(let host)):
            problem = "That code is for another household (\(host)), not \(address.host)."
        case .failure(.unreadable):
            problem = "That isn't an enrollment code. Ask your administrator to show it again on the Members card."
        }
    }
}

/// The camera, reading QR codes until one is found. VisionKit's scanner asks for the camera itself
/// (NSCameraUsageDescription).
struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
