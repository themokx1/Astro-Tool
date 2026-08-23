import AVFoundation
import Foundation
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

struct CameraQRScannerView: UIViewRepresentable {
    let scanner: any MobileQRScanner

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = scanner.session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.preview.session = scanner.session
    }

    final class PreviewView: UIView {
        let preview = AVCaptureVideoPreviewLayer()
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override init(frame: CGRect) {
            super.init(frame: frame)
            preview.videoGravity = .resizeAspectFill
            layer.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); preview.frame = bounds }
    }
}
#elseif canImport(SwiftUI)
import SwiftUI
struct CameraQRScannerView: View {
    let scanner: any MobileQRScanner
    var body: some View { Color.black.frame(minHeight: 220) }
}
#endif

@MainActor
public protocol MobileQRScanner: AnyObject {
    var session: AVCaptureSession { get }
    var onPayload: ((String) -> Void)? { get set }
    func start() throws
    func stop()
}

@MainActor
public final class CameraQRScanner: NSObject, MobileQRScanner, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    public let session = AVCaptureSession()
    public var onPayload: ((String) -> Void)?
    private var isConfigured = false

    public func start() throws {
        guard !isConfigured else { session.startRunning(); return }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw ScannerError.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw ScannerError.cameraUnavailable }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw ScannerError.cameraUnavailable }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        isConfigured = true
        session.startRunning()
    }

    public func stop() {
        if session.isRunning { session.stopRunning() }
        onPayload = nil
    }

    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        onPayload?(value)
    }

    enum ScannerError: Error { case cameraUnavailable }
}
