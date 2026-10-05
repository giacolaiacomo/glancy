import AVFoundation
import AppKit
import SwiftUI

// Camera mirror: a live front-camera preview inside the panel. The capture session exists only
// while the preview view is on screen (Control tab open, mirror on); it stops when the view goes
// away (tab change, collapse, panel destroyed), so the camera light never stays on.

enum CameraPermission {
    /// Asking without a usage string kills the process (tests, `swift run`, the renderer).
    static var usable: Bool { Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil }

    static func status() -> CameraAccess {
        guard usable else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func request() async -> Bool {
        guard usable else { return false }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}

/// Owns one capture session; started and stopped on its own queue.
final class MirrorCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ai.glancy.control.mirror")
    private var configured = false

    func start() {
        queue.async { [self] in
            if !configured {
                configured = true
                session.beginConfiguration()
                session.sessionPreset = .medium
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                    ?? AVCaptureDevice.default(for: .video)
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            if !session.isRunning, !session.inputs.isEmpty { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            for input in session.inputs { session.removeInput(input) }
            configured = false
        }
    }
}

/// The preview layer, mirrored like a mirror. Starts on appear, stops when dismantled.
struct MirrorPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.capture.start()
        return v
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.capture.stop()
    }

    final class PreviewView: NSView {
        let capture = MirrorCapture()
        private let preview: AVCaptureVideoPreviewLayer

        override init(frame: NSRect) {
            preview = AVCaptureVideoPreviewLayer(session: capture.session)
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            preview.videoGravity = .resizeAspectFill
            // Flipped like a mirror (the connection doesn't exist until the camera is attached).
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { capture.stop() }
        }
    }
}
