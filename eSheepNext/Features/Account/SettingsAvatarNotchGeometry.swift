import CoreGraphics

/// Decorative attachment inside a known sensor housing. Safe-area insets alone
/// cannot distinguish a notch from another status-bar configuration.
enum SettingsAvatarNotchGeometry {
    enum Profile: Equatable, Sendable {
        case wide
        case narrow
    }

    struct Attachment: Equatable, Sendable {
        let anchorY: CGFloat
        let contact: SettingsAvatarIslandGeometry.Contact
    }

    static func profile(for identifier: String) -> Profile? {
        switch identifier {
        // iPhone 11 and 12 families supported by the app's deployment target.
        case "iPhone12,1", "iPhone12,3", "iPhone12,5",
             "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4":
            return .wide
        // iPhone 13 family, 14 / 14 Plus, 16e and 17e.
        case "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
             "iPhone14,7", "iPhone14,8", "iPhone17,5", "iPhone18,5":
            return .narrow
        default:
            return nil
        }
    }

    static func attachment(
        for identifier: String, viewportWidth: CGFloat,
        topInset: CGFloat, displayScale: CGFloat
    ) -> Attachment? {
        guard let profile = profile(for: identifier),
              viewportWidth.isFinite, viewportWidth > 0,
              topInset.isFinite, (44..<59).contains(topInset) else { return nil }
        let scale = displayScale.isFinite ? max(1, displayScale) : 1
        let pixel = 1 / scale
        return Attachment(
            // Translate the existing silhouette with the avatar's status-bar
            // baseline. Its root is overscanned into the housing so there is
            // no visible gap at the hardware edge.
            anchorY: topInset - 11.5,
            contact: SettingsAvatarIslandGeometry.Contact(
                // This is a software shoulder, deliberately narrower than the
                // notch; it does not draw a replacement hardware silhouette.
                halfWidth: min(profile == .wide ? 70 : 58, viewportWidth / 5),
                top: -4 - pixel,
                paintOverscan: 6 + pixel,
                pixel: pixel
            )
        )
    }
}
