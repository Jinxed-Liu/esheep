import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum MotionHapticCue: String, Codable, Sendable {
    case selection
    case lightImpact
    case mediumImpact
    case heavyImpact
    case success
    case warning
    case error
}

@MainActor
public enum MotionHaptics {
    public static func play(
        _ cue: MotionHapticCue,
        isEnabled: Bool = true
    ) {
        guard isEnabled else { return }

        #if os(iOS)
        switch cue {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavyImpact:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #elseif os(macOS)
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch cue {
        case .selection, .lightImpact:
            pattern = .alignment
        case .mediumImpact, .heavyImpact, .success, .warning, .error:
            pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(
            pattern,
            performanceTime: .now
        )
        #endif
    }
}
