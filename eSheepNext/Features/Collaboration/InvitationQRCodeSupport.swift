import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import VisionKit

enum FarmInvitationQRCodeGenerator {
    private static let context = CIContext()

    static func image(for value: String, dimension: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let scale = max(
            1,
            floor(dimension / max(extent.width, extent.height))
        )
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        guard let image = context.createCGImage(
            transformed,
            from: transformed.extent
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

struct FarmInvitationDataScanner: UIViewControllerRepresentable {
    let onValue: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onValue: onValue)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {
        guard !uiViewController.isScanning else { return }
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onValue: (String) -> Void
        private var lastValue: String?

        init(onValue: @escaping (String) -> Void) {
            self.onValue = onValue
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      value != lastValue else {
                    continue
                }
                lastValue = value
                onValue(value)
                return
            }
        }
    }
}
