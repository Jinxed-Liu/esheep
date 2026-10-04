import CoreGraphics
import Darwin
import Foundation

/// Keep compact-model shoulders inside the existing software clip without
/// replacing the original flared neck with a narrow capsule-like outline.
enum SettingsAvatarIslandGeometry {
    struct Contact: Equatable {
        let halfWidth: CGFloat
        let top: CGFloat
        let paintOverscan: CGFloat
        let pixel: CGFloat
    }

    private static let deviceIdentifier = currentDeviceIdentifier()

    static func usesCompactAttachment(deviceIdentifier: String) -> Bool {
        switch deviceIdentifier {
        case "iPhone19,2", "iPhone19,3", "iPhone19,7":
            return true
        default:
            return false
        }
    }

    static func currentContact(viewportWidth: CGFloat, displayScale: CGFloat) -> Contact? {
        contact(for: deviceIdentifier, viewportWidth: viewportWidth, displayScale: displayScale)
    }

    static func contact(
        for deviceIdentifier: String, viewportWidth: CGFloat, displayScale: CGFloat
    ) -> Contact? {
        guard usesCompactAttachment(deviceIdentifier: deviceIdentifier),
              viewportWidth.isFinite, viewportWidth > 0 else { return nil }
        let scale = displayScale.isFinite ? max(1, displayScale) : 1
        let pixel = 1 / scale
        return Contact(
            // A W/2.5 corner radius leaves W/10 on each side at the clip's
            // flat top. This is software geometry, not a hardware measurement.
            halfWidth: max(0, min(45.7, viewportWidth / 10) - pixel),
            // The 47pt outer clip is 0.5pt above the 47.5pt mask canvas.
            // Begin the smooth connection one pixel above that visible edge.
            top: -0.5 - pixel,
            // Cover the entire connection strip, including its antialiased
            // edge. A mask cannot provide pixels outside the painted layers.
            paintOverscan: 2 + pixel,
            pixel: pixel
        )
    }

    static func paintBounds(in bounds: CGRect, topOverscan: CGFloat) -> CGRect {
        let overscan = topOverscan.isFinite ? max(0, topOverscan) : 0
        return CGRect(
            x: bounds.minX, y: bounds.minY - overscan,
            width: bounds.width, height: bounds.height + overscan
        )
    }

    private static func currentDeviceIdentifier() -> String {
#if targetEnvironment(simulator)
        if let simulatedModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatedModel
        }
#endif
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
