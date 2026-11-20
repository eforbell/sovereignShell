import AVFoundation
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
    /// What a scan found, opened once the scanner has gone: one presentation at a time.
    @State private var scanned: URL?
    @State private var problem: String?
    @State private var cameraDenied = false
    @Environment(\.openURL) private var openURL

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
                Button("Scan code", systemImage: "qrcode.viewfinder") { Task { await scan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!DataScannerViewController.isSupported)
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in pasted(text) }
                }
                .labelStyle(.titleAndIcon)
            }
            if !DataScannerViewController.isSupported {
                Text("This phone can't scan codes. Paste the code instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if cameraDenied {
                Button("Allow the camera in Settings") {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }
                .font(.footnote)
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
        .sheet(isPresented: $scanning, onDismiss: {
            if let url = scanned {
                scanned = nil
                open(url)
            }
        }) {
            NavigationStack {
                CodeScanner(accept: accept) { failure in
                    scanning = false
                    problem = failure
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

    /// The camera, asked for the first time if need be; then the scanner.
    private func scan() async {
        problem = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return deny() }
            cameraDenied = false
        default:
            return deny()
        }
        guard DataScannerViewController.isAvailable else {
            problem = "The camera isn't available right now. Paste the code instead."
            return
        }
        scanning = true
    }

    private func deny() {
        cameraDenied = true
        problem = "Home Base can't use the camera. Allow it in Settings, or paste the code."
    }

    /// A QR code the scanner read: true if it's done (this household's code, or another household's, which
    /// is worth saying). Other codes in view are ignored and scanning goes on.
    private func accept(_ text: String) -> Bool {
        switch EnrollmentCode.parse(text, from: .scanned, for: address) {
        case .success(let code):
            problem = nil
            scanned = address.addPasskey(code: code)
            scanning = false
            return true
        case .failure(.otherHousehold(let host)):
            problem = Self.otherHousehold(host, address: address)
            scanning = false
            return true
        case .failure(.unreadable):
            return false
        }
    }

    private func pasted(_ text: String) {
        switch EnrollmentCode.parse(text, from: .pasted, for: address) {
        case .success(let code):
            problem = nil
            open(address.addPasskey(code: code))
        case .failure(.otherHousehold(let host)):
            problem = Self.otherHousehold(host, address: address)
        case .failure(.unreadable):
            problem = "That isn't an enrollment code. Ask your administrator to show it again on the Members card."
        }
    }

    private static func otherHousehold(_ host: String?, address: HomeBaseAddress) -> String {
        "That code is for another household\(host.map { " (\($0))" } ?? ""), not \(address.host)."
    }
}

/// The camera, reading QR codes until `accept` takes one. Scanning starts once the scanner is on screen;
/// if it can't, `failed` says why.
struct CodeScanner: UIViewControllerRepresentable {
    let accept: (String) -> Bool
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !context.coordinator.started else { return }
        context.coordinator.started = true
        // After this update, when the sheet has put the scanner on screen.
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                failed("The camera couldn't start (\(error.localizedDescription)). Paste the code instead.")
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.done = true
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(accept: accept) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let accept: (String) -> Bool
        var started = false
        var done = false
        init(accept: @escaping (String) -> Bool) { self.accept = accept }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue, accept(text) {
                    done = true
                    scanner.stopScanning()
                    return
                }
            }
        }
    }
}
