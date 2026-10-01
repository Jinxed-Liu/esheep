import SwiftUI
import UIKit

/// Reserves the avatar's space in the scroll content. The single image lives
/// in SettingsAvatarOverlay so the header and navigation bar never duplicate it.
@MainActor
struct SettingsAvatarHeader: View {
    let account: AccountProfile
    let farm: FarmRecord
    let motion: AccountAvatarMotionCoordinator

    private var expandedSide: CGFloat {
        max(96, min(motion.availableWidth, 420))
    }

    var body: some View {
        VStack(spacing: 11) {
            Color.clear
                .frame(height: 96 + (expandedSide - 96) * motion.expansion)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    motion.updateSourceFrame(frame)
                }

            VStack(spacing: 4) {
                Text(account.displayName)
                    .font(.title2.bold())
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(verbatim: farm.name)
                    Text(" · ")
                    Text(LocalizedStringKey(farm.role.displayName))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .opacity(1 - motion.titleProgress)
            .offset(y: motion.animationsEnabled ? -6 * motion.titleProgress : 0)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(motion.titleProgress > 0.95)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            motion.updateAvailableWidth(width)
        }
    }
}

/// Only the bounded avatar button receives touches; the rest of the overlay
/// and its window probe let the settings scroll view receive input.
@MainActor
struct SettingsAvatarOverlay: View {
    let account: AccountProfile
    let motion: AccountAvatarMotionCoordinator
    let namespace: Namespace.ID
    let onTap: () -> Void
    let onEdit: () -> Void

    @State private var windowMetrics = SettingsAvatarWindowMetrics.empty

    var body: some View {
        GeometryReader { geometry in
            let layout = avatarLayout(in: geometry)
            ZStack(alignment: .topLeading) {
                if !layout.frame.isEmpty {
                    avatarButton(layout: layout)
                        .position(x: layout.frame.midX, y: layout.frame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background {
                SettingsAvatarWindowProbe { metrics in
                    if windowMetrics != metrics {
                        windowMetrics = metrics
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func avatarButton(layout: SettingsAvatarOverlayLayout) -> some View {
        let contour = SettingsAvatarContour(
            expansion: layout.expansion,
            islandProgress: layout.islandProgress
        )
        return Button(action: onTap) {
            SettingsAvatarImage(
                account: account,
                motion: motion,
                targetSide: max(96, min(motion.availableWidth, 420))
            )
            .frame(width: layout.frame.width, height: layout.frame.height)
            .overlay {
                AvatarIslandEffectView(progress: layout.islandProgress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipShape(contour)
            .overlay {
                contour.stroke(.primary.opacity(0.05 * (1 - layout.islandProgress)), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(contour)
        }
        .buttonStyle(.plain)
        .frame(width: layout.frame.width, height: layout.frame.height)
        .contentShape(contour)
        .matchedTransitionSource(id: account.id, in: namespace)
        .opacity(layout.opacity)
        .disabled(layout.opacity < 0.01 || layout.islandProgress >= 1)
        .allowsHitTesting(layout.opacity >= 0.01 && layout.islandProgress < 1)
        .accessibilityLabel("头像")
        .accessibilityHint("点按查看头像")
        .accessibilityIdentifier("account-avatar-entry")
        .accessibilityHidden(layout.opacity < 0.01)
        .accessibilityAction(named: Text("更换头像"), onEdit)
    }

    private func avatarLayout(in geometry: GeometryProxy) -> SettingsAvatarOverlayLayout {
        let source = motion.sourceFrame
        guard source.width > 0, source.height > 0 else { return .empty }

        let origin = geometry.frame(in: .global).origin
        let squareSide = max(96, min(motion.availableWidth, 420))

        // The placeholder's measured height follows the spring's presentation.
        // Reading only the model's target expansion would jump the overlay
        // directly to a square before the scroll layout finishes expanding.
        let expansion = squareSide > 96
            ? boundedSettingsAvatarProgress((source.height - 96) / (squareSide - 96))
            : boundedSettingsAvatarProgress(motion.expansion)
        let stretch = motion.animationsEnabled
            ? 1 + min(max(-motion.scrollOffset, 0) / squareSide, 0.16)
            : 1
        let side = source.height * stretch
        let ordinaryFrame = CGRect(
            x: source.midX - origin.x - side / 2,
            y: source.midY - origin.y - side / 2,
            width: side,
            height: side
        )

        let mergeWithIsland = windowMetrics.supportsIsland && motion.animationsEnabled
        let collapse = motion.animationsEnabled
            ? boundedSettingsAvatarProgress(motion.scrollOffset / 120)
            : motion.titleProgress
        let islandProgress = mergeWithIsland ? collapse * (1 - expansion) : 0

        let frame: CGRect
        let opacity: CGFloat
        if mergeWithIsland {
            // AvatarIslandMask exposes only the top 34% of this square at p=1.
            // Its 39.44pt capsule aligns with the physical top-center cutout.
            let target = CGRect(
                x: windowMetrics.islandCenter.x - 58,
                y: windowMetrics.islandCenter.y - 19.7,
                width: 116,
                height: 116
            )
            frame = CGRect(
                x: ordinaryFrame.minX + (target.minX - ordinaryFrame.minX) * islandProgress,
                y: ordinaryFrame.minY + (target.minY - ordinaryFrame.minY) * islandProgress,
                width: ordinaryFrame.width + (target.width - ordinaryFrame.width) * islandProgress,
                height: ordinaryFrame.height + (target.height - ordinaryFrame.height) * islandProgress
            )
            opacity = 1 - boundedSettingsAvatarProgress((islandProgress - 0.9) / 0.1)
        } else {
            frame = ordinaryFrame
            opacity = 1 - collapse * (1 - expansion)
        }
        return SettingsAvatarOverlayLayout(
            frame: frame,
            expansion: expansion,
            islandProgress: islandProgress,
            opacity: opacity
        )
    }
}

/// Uses the existing thumbnail service with a fixed layout-size request.
/// The coordinator keeps the same decoded photo as the viewer's entrance seed.
@MainActor
struct SettingsAvatarImage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let account: AccountProfile
    let motion: AccountAvatarMotionCoordinator
    let targetSide: CGFloat

    @State private var thumbnail: ImageThumbnail?
    @State private var loadedDigest: String?

    var body: some View {
        Group {
            if let thumbnail, loadedDigest == digest {
                Image(decorative: thumbnail.cgImage, scale: thumbnail.scale, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallbackAvatar
            }
        }
        .accessibilityHidden(true)
        .task(id: requestID) {
            let requestedDigest = digest
            guard let data = account.avatarImageData else {
                thumbnail = nil
                loadedDigest = nil
                return
            }
            let loaded = await ImageThumbnailPipeline.shared.thumbnail(
                data: data,
                digest: requestedDigest,
                targetSize: CGSize(width: targetSide, height: targetSide),
                scale: displayScale
            )
            guard !Task.isCancelled, requestedDigest == digest else { return }
            thumbnail = loaded
            loadedDigest = requestedDigest
            if let loaded {
                motion.storePreview(loaded, digest: requestedDigest)
            }
        }
    }

    private var digest: String {
        account.avatarCloudDigest ??
            "account-avatar|\(account.id.uuidString)|\(account.updatedAt.timeIntervalSince1970)|\(account.avatarImageData?.count ?? 0)"
    }

    private var requestID: RequestID {
        RequestID(
            digest: digest,
            pixelSide: Int(ceil(targetSide * displayScale))
        )
    }

    private var fallbackAvatar: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(AppTheme.brand.opacity(colorScheme == .dark ? 0.24 : 0.10))
                Text(initials)
                    .font(.system(
                        size: min(geometry.size.width, geometry.size.height) * 0.36,
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(colorScheme == .dark ? AppTheme.brandSoft : AppTheme.brand)
            }
        }
    }

    private var initials: String {
        account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .first.map(String.init) ?? "羊"
    }

    private struct RequestID: Hashable {
        let digest: String
        let pixelSide: Int
    }
}

private struct SettingsAvatarContour: Shape {
    var expansion: CGFloat
    var islandProgress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(expansion, islandProgress) }
        set {
            expansion = newValue.first
            islandProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let expansion = boundedSettingsAvatarProgress(expansion)
        let islandProgress = boundedSettingsAvatarProgress(islandProgress)
        let morph = islandProgress * islandProgress * (3 - 2 * islandProgress)
        let diameter = min(rect.width, rect.height)
        let width = diameter + (rect.width - diameter) * morph
        let height = diameter * (1 - 0.66 * morph)
        let initialTop = rect.midY - diameter / 2
        let top = initialTop + (rect.minY - initialTop) * morph
        let bounds = CGRect(
            x: rect.midX - width / 2, y: top, width: width, height: height
        )
        let circleRadius = min(bounds.width, bounds.height) / 2
        let radius = circleRadius + (min(12, circleRadius) - circleRadius) * expansion
        let control = radius * 0.5522847498307936
        let left = bounds.minX
        let right = bounds.maxX
        let bottom = bounds.maxY

        // Both stages share the original island mask's eight cubic segments.
        // Expansion changes the radius while islandProgress flattens the bounds,
        // so reversing either input preserves every control-point correspondence.
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        addStraightCurve(
            to: &path,
            from: CGPoint(x: left + radius, y: top),
            to: CGPoint(x: right - radius, y: top)
        )
        path.addCurve(
            to: CGPoint(x: right, y: top + radius),
            control1: CGPoint(x: right - radius + control, y: top),
            control2: CGPoint(x: right, y: top + radius - control)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: right, y: top + radius),
            to: CGPoint(x: right, y: bottom - radius)
        )
        path.addCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control1: CGPoint(x: right, y: bottom - radius + control),
            control2: CGPoint(x: right - radius + control, y: bottom)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: right - radius, y: bottom),
            to: CGPoint(x: left + radius, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control1: CGPoint(x: left + radius - control, y: bottom),
            control2: CGPoint(x: left, y: bottom - radius + control)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: left, y: bottom - radius),
            to: CGPoint(x: left, y: top + radius)
        )
        path.addCurve(
            to: CGPoint(x: left + radius, y: top),
            control1: CGPoint(x: left, y: top + radius - control),
            control2: CGPoint(x: left + radius - control, y: top)
        )
        path.closeSubpath()
        return path
    }

    private func addStraightCurve(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint
    ) {
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + delta.x / 3, y: start.y + delta.y / 3),
            control2: CGPoint(x: start.x + delta.x * 2 / 3, y: start.y + delta.y * 2 / 3)
        )
    }
}

private struct SettingsAvatarOverlayLayout {
    let frame: CGRect
    let expansion: CGFloat
    let islandProgress: CGFloat
    let opacity: CGFloat

    static let empty = Self(frame: .zero, expansion: 0, islandProgress: 0, opacity: 0)
}

private struct SettingsAvatarWindowMetrics: Equatable, Sendable {
    let supportsIsland: Bool
    let islandCenter: CGPoint

    static let empty = Self(supportsIsland: false, islandCenter: .zero)
}

@MainActor
private struct SettingsAvatarWindowProbe: UIViewRepresentable {
    let onUpdate: @MainActor (SettingsAvatarWindowMetrics) -> Void

    func makeUIView(context: Context) -> SettingsAvatarWindowProbeUIView {
        let view = SettingsAvatarWindowProbeUIView(frame: .zero)
        view.onUpdate = onUpdate
        return view
    }

    func updateUIView(_ uiView: SettingsAvatarWindowProbeUIView, context: Context) {
        uiView.onUpdate = onUpdate
        uiView.refresh()
    }

    static func dismantleUIView(_ uiView: SettingsAvatarWindowProbeUIView, coordinator: ()) {
        uiView.invalidate()
    }
}

@MainActor
private final class SettingsAvatarWindowProbeUIView: UIView {
    var onUpdate: (@MainActor (SettingsAvatarWindowMetrics) -> Void)?
    private var lastMetrics: SettingsAvatarWindowMetrics?
    private var pendingUpdate: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    func refresh() {
        let metrics: SettingsAvatarWindowMetrics
        if let window {
            guard !bounds.isEmpty else { return }
            let safeTop = window.safeAreaInsets.top
            let portrait = window.windowScene?.interfaceOrientation.isPortrait
                ?? (window.bounds.height > window.bounds.width)
            metrics = SettingsAvatarWindowMetrics(
                supportsIsland: window.traitCollection.userInterfaceIdiom == .phone
                    && portrait && safeTop >= 59,
                islandCenter: convert(
                    CGPoint(x: window.bounds.midX, y: safeTop / 2),
                    from: window
                )
            )
        } else {
            metrics = .empty
        }
        guard lastMetrics != metrics else { return }
        lastMetrics = metrics
        pendingUpdate?.cancel()
        // Publish after UIKit layout instead of mutating SwiftUI state from
        // updateUIView or a synchronous layout callback.
        pendingUpdate = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pendingUpdate = nil
            self.onUpdate?(metrics)
        }
    }

    func invalidate() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        onUpdate = nil
    }
}

private func boundedSettingsAvatarProgress(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}
