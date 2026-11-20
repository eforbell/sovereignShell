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
        case .restricted:
            // Screen Time, say: Settings can't change it here.
            problem = "The camera is restricted on this phone. Paste the code instead."
            return
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
            // The Members card's own format, but not a code this app reads: say so rather than scan on.
            guard text.hasPrefix("sovereign-grant/") else { return false }
            problem = text.hasPrefix("sovereign-grant/1")
                ? "That code didn't read. Ask your administrator to issue a new one, or paste it."
                : "This code is from a newer Home Base. Update this app to scan it, or paste the code."
            scanning = false
            return true
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

/// The camera, reading QR codes until `accept` takes one. Scanning starts when the scanner is on screen
/// (viewDidAppear) and stops when it leaves; if it can't start, `failed` says why.
struct CodeScanner: UIViewControllerRepresentable {
    let accept: (String) -> Bool
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        ScannerHost(accept: accept, failed: failed)
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {}

    /// Hosts VisionKit's scanner (which can't be subclassed) to start it at the right moment.
    final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
        private let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        private let accept: (String) -> Bool
        private let failed: (String) -> Void
        private var done = false

        init(accept: @escaping (String) -> Bool, failed: @escaping (String) -> Void) {
            self.accept = accept
            self.failed = failed
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a storyboard") }

        override func viewDidLoad() {
            super.viewDidLoad()
            scanner.delegate = self
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !done, !scanner.isScanning else { return }
            do {
                try scanner.startScanning()
            } catch {
                done = true
                failed("The camera couldn't start (\(error.localizedDescription)). Paste the code instead.")
            }
        }

        // Only stopped: a swipe-down let go springs back, and viewDidAppear starts it again. done is for a
        // code taken, or a camera that won't start.
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }

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
