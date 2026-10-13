import Lottie
import SwiftUI

public enum MotionContentMode: Sendable {
    case fit
    case fill
}

public struct MotionLottieView: View {
    private let source: MotionLottieSource
    private let playback: MotionLottiePlayback
    private let bundle: Bundle
    private let contentMode: MotionContentMode

    @State private var preparedSource: MotionLottieSource?
    @State private var loadError: Error?

    public init(
        source: MotionLottieSource,
        playback: MotionLottiePlayback = .playOnce,
        bundle: Bundle = .main,
        contentMode: MotionContentMode = .fit
    ) {
        self.source = source
        self.playback = playback
        self.bundle = bundle
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let preparedSource {
                lottieContent(for: preparedSource)
            } else if loadError != nil {
                Color.clear
                    .accessibilityLabel("Motion asset failed to load")
            } else {
                Color.clear
            }
        }
        .task(id: source) {
            do {
                preparedSource = try await MotionAssetCache.shared.prepare(source)
                loadError = nil
            } catch {
                preparedSource = nil
                loadError = error
            }
        }
    }

    @ViewBuilder
    private func lottieContent(
        for source: MotionLottieSource
    ) -> some View {
        switch source {
        case .named(let name):
            configured(
                LottieView(
                    animation: LottieAnimation.named(name, bundle: bundle)
                )
            )
        case .localFile(let url):
            configured(
                LottieView {
                    await LottieAnimation.loadedFrom(url: url)
                }
            )
        case .remote:
            Color.clear
        }
    }

    private func configured<Placeholder: View>(
        _ view: LottieView<Placeholder>
    ) -> some View {
        view
            .playbackMode(playback.lottiePlaybackMode)
            .configure { animationView in
                #if os(iOS)
                animationView.contentMode = switch contentMode {
                case .fit:
                    .scaleAspectFit
                case .fill:
                    .scaleAspectFill
                }
                #endif
                animationView.shouldRasterizeWhenIdle = true
            }
            .accessibilityHidden(true)
    }
}

extension MotionLottiePlayback {
    fileprivate var lottiePlaybackMode: LottiePlaybackMode {
        switch self {
        case .paused(let progress):
            return .paused(at: .progress(min(max(progress, 0), 1)))
        case .playing(let fromProgress, let toProgress, let loopMode):
            return .playing(
                .fromProgress(
                    min(max(fromProgress, 0), 1),
                    toProgress: min(max(toProgress, 0), 1),
                    loopMode: loopMode.lottieLoopMode
                )
            )
        }
    }
}

extension MotionLottieLoopMode {
    fileprivate var lottieLoopMode: LottieLoopMode {
        switch self {
        case .playOnce:
            .playOnce
        case .loop:
            .loop
        case .autoReverse:
            .autoReverse
        }
    }
}
