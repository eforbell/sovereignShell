import AVFoundation
import SwiftUI
import VisionKit

/// Whether the camera can scan: asked for the first time if need be.
enum CameraAccess {
    enum Outcome: Equatable {
        case ready
        /// Refused in Settings: the person can allow it there.
        case denied
        /// Not this time, and why (restricted, or busy), for the caller to add what to do instead.
        case unavailable(String)
    }

    @MainActor static func ask() async -> Outcome {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        case .restricted:
            // Screen Time, say: Settings can't change it here.
            return .unavailable("The camera is restricted on this phone.")
        default:
            return .denied
        }
        guard DataScannerViewController.isAvailable else {
            return .unavailable("The camera isn't available right now.")
        }
        return .ready
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
                failed("The camera couldn't start (\(error.localizedDescription)).")
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
