import SwiftUI
import UIKit

/// The settings screen owns presentation and the matching zoom transition source.
@MainActor
struct AccountAvatarViewer: View {
    @Environment(\.displayScale) private var displayScale

    let account: AccountProfile
    let reduceMotion: Bool
    let onPresented: () -> Void
    let onClose: () -> Void
    let onEdit: () -> Void

    @State private var image: UIImage?
    @State private var loadedDigest: String?
    @State private var dragProgress: CGFloat = 0
    @State private var hasReportedPresentation = false
    @State private var hasRequestedExit = false

    init(
        account: AccountProfile,
        reduceMotion: Bool,
        initialImage: UIImage? = nil,
        initialDigest: String? = nil,
        onPresented: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        self.account = account
        self.reduceMotion = reduceMotion
        self.onPresented = onPresented
        self.onClose = onClose
        self.onEdit = onEdit
        // One-time seeds for this full-screen presentation preserve the source
        // photo during entry. Account changes still reload through the image task,
        // and a seed is displayed only while its digest matches the current request.
        _image = State(initialValue: initialImage)
        _loadedDigest = State(initialValue: initialDigest)
    }

    var body: some View {
        GeometryReader { geometry in
            let request = imageRequest(for: geometry.size)
            AccountAvatarZoomView(
                image: loadedDigest == request.digest ? image : nil,
                imageID: request.digest,
                initials: initials,
                reduceMotion: reduceMotion,
                onDragProgress: updateDragProgress,
                onClose: requestClose
            )
            .task(id: request) {
                await loadImage(for: request, viewport: geometry.size)
            }
        }
        .background(Color.black.opacity(backgroundOpacity).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: requestClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("account-avatar-viewer-close")

                Text(account.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(controlsOpacity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: requestEdit) {
                Label("更换头像", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 20)
                    .background(.white.opacity(0.14), in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .opacity(controlsOpacity)
            .accessibilityIdentifier("account-avatar-viewer-edit")
        }
        .background {
            AccountAvatarPresentationObserver(onPresented: reportPresentation)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        // One pan recognizer owns dismissal. Programmatic dismissal still uses
        // the native zoom transition supplied by SettingsHomeView.
        .interactiveDismissDisabled(true)
        .accessibilityAction(.escape) {
            requestClose()
        }
        .onDisappear {
            // Also covers dismissal initiated by the system or presentation owner.
            requestClose()
        }
    }

    private var initials: String {
        account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .first.map(String.init) ?? "羊"
    }

    private var backgroundOpacity: Double {
        reduceMotion ? 1 : Double(1 - min(dragProgress, 1) * 0.4)
    }

    private var controlsOpacity: Double {
        reduceMotion ? 1 : Double(1 - min(dragProgress * 2, 1))
    }

    private func imageRequest(for viewport: CGSize) -> ImageRequest {
        let digest: String
        if let data = account.avatarImageData {
            digest = account.avatarCloudDigest ??
                "account-avatar|\(account.id.uuidString)|\(account.updatedAt.timeIntervalSince1970)|\(data.count)"
        } else {
            digest = "account-avatar|\(account.id.uuidString)|empty"
        }
        return ImageRequest(
            digest: digest,
            pixelWidth: max(1, Int(ceil(viewport.width * displayScale * 2))),
            pixelHeight: max(1, Int(ceil(viewport.height * displayScale * 2))),
            scale: displayScale
        )
    }

    private func loadImage(for request: ImageRequest, viewport: CGSize) async {
        guard viewport.width > 0, viewport.height > 0,
              let data = account.avatarImageData else {
            image = nil
            loadedDigest = request.digest
            return
        }
        let thumbnail = await ImageThumbnailPipeline.shared.thumbnail(
            data: data,
            digest: request.digest,
            targetSize: CGSize(width: viewport.width * 2, height: viewport.height * 2),
            scale: request.scale
        )
        guard !Task.isCancelled,
              imageRequest(for: viewport).digest == request.digest else { return }
        image = thumbnail.map {
            UIImage(cgImage: $0.cgImage, scale: $0.scale, orientation: .up)
        }
        loadedDigest = request.digest
    }

    private func updateDragProgress(_ progress: CGFloat, animated: Bool) {
        guard !hasRequestedExit else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                dragProgress = progress
            }
        } else {
            dragProgress = progress
        }
    }

    private func reportPresentation() {
        guard !hasReportedPresentation, !hasRequestedExit else { return }
        hasReportedPresentation = true
        onPresented()
    }

    private func requestClose() {
        guard !hasRequestedExit else { return }
        hasRequestedExit = true
        onClose()
    }

    private func requestEdit() {
        guard !hasRequestedExit else { return }
        hasRequestedExit = true
        onEdit()
    }

    private struct ImageRequest: Hashable {
        let digest: String
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat
    }
}

@MainActor
private struct AccountAvatarZoomView: UIViewRepresentable {
    let image: UIImage?
    let imageID: String
    let initials: String
    let reduceMotion: Bool
    let onDragProgress: (CGFloat, Bool) -> Void
    let onClose: () -> Void

    func makeUIView(context: Context) -> AccountAvatarZoomContainer {
        AccountAvatarZoomContainer()
    }

    func updateUIView(_ view: AccountAvatarZoomContainer, context: Context) {
        view.onDragProgress = onDragProgress
        view.onClose = onClose
        view.reduceMotion = reduceMotion
        view.setImage(image, id: imageID, initials: initials)
    }

    static func dismantleUIView(_ view: AccountAvatarZoomContainer, coordinator: ()) {
        view.onDragProgress = nil
        view.onClose = nil
        view.scrollView.delegate = nil
        view.cancelAnimations()
    }
}

@MainActor
private final class AccountAvatarZoomContainer: UIView,
    UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()

    var onDragProgress: ((CGFloat, Bool) -> Void)?
    var onClose: (() -> Void)?
    var reduceMotion = false {
        didSet {
            scrollView.bounces = !reduceMotion
            scrollView.bouncesZoom = !reduceMotion
            if reduceMotion {
                cancelAnimations()
                scrollView.transform = .identity
            }
        }
    }

    private let canvas = UIView()
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()
    private var imageID: String?
    private var viewport = CGSize.zero
    private var imageNeedsLayout = true
    private var resetsZoom = true
    private var isLayingOut = false
    private var isDismissing = false
    private var returnAnimator: UIViewPropertyAnimator?
    private var dismissalStartTranslation = CGPoint.zero

    private lazy var dismissPan = UIPanGestureRecognizer(
        target: self, action: #selector(handleDismissPan(_:))
    )
    private lazy var doubleTap = UITapGestureRecognizer(
        target: self, action: #selector(handleDoubleTap(_:))
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.scrollsToTop = false
        addSubview(scrollView)
        scrollView.addSubview(canvas)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        canvas.addSubview(imageView)

        initialsLabel.font = .systemFont(ofSize: 96, weight: .medium)
        initialsLabel.textAlignment = .center
        initialsLabel.textColor = .white
        initialsLabel.backgroundColor = UIColor(AppTheme.brand)
        initialsLabel.isAccessibilityElement = false
        canvas.addSubview(initialsLabel)

        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = self
        addGestureRecognizer(dismissPan)
        // At 1x a downward pan belongs to dismissal; at larger zoom levels it
        // fails immediately and UIScrollView pans the image normally.
        scrollView.panGestureRecognizer.require(toFail: dismissPan)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)

        isAccessibilityElement = true
        accessibilityTraits = [.image, .adjustable]
        accessibilityLabel = String(localized: "头像")
        accessibilityHint = String(localized: "双指缩放，或使用放大和缩小操作")
        accessibilityIdentifier = "account-avatar-viewer-image"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "放大头像"),
                target: self, selector: #selector(handleAvatarZoomIn)
            ),
            UIAccessibilityCustomAction(
                name: String(localized: "缩小头像"),
                target: self, selector: #selector(handleAvatarZoomOut)
            ),
            UIAccessibilityCustomAction(
                name: String(localized: "还原头像大小"),
                target: self, selector: #selector(handleAvatarResetZoom)
            ),
        ]
        updateAccessibilityValue()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setImage(_ image: UIImage?, id: String, initials: String) {
        let changedIdentity = imageID != id
        if imageView.image !== image || changedIdentity {
            imageView.image = image
            imageID = id
            imageNeedsLayout = true
            resetsZoom = resetsZoom || changedIdentity
            setNeedsLayout()
        }
        initialsLabel.text = initials
        initialsLabel.isHidden = image != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOut, bounds.width > 0, bounds.height > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        // Updating bounds.size and center preserves both the scroll offset and
        // a dismissal transform; assigning frame would reset a transformed view.
        scrollView.bounds.size = bounds.size
        scrollView.center = CGPoint(x: bounds.midX, y: bounds.midY)

        guard viewport != bounds.size || imageNeedsLayout else { return }
        let previousScale = scrollView.zoomScale
        let previousContentSize = scrollView.contentSize
        let normalizedCenter = CGPoint(
            x: (scrollView.contentOffset.x + viewport.width / 2) /
                max(previousContentSize.width, 1),
            y: (scrollView.contentOffset.y + viewport.height / 2) /
                max(previousContentSize.height, 1)
        )
        let shouldRestoreZoom = viewport != .zero && !resetsZoom
        viewport = bounds.size
        imageNeedsLayout = false

        scrollView.setZoomScale(1, animated: false)
        let size = fittedImageSize(in: viewport)
        canvas.frame = CGRect(origin: .zero, size: size)
        imageView.frame = canvas.bounds
        initialsLabel.frame = canvas.bounds
        scrollView.contentSize = size

        if shouldRestoreZoom {
            scrollView.setZoomScale(previousScale, animated: false)
        }
        centerCanvas()

        if shouldRestoreZoom {
            let offset = CGPoint(
                x: normalizedCenter.x * scrollView.contentSize.width - viewport.width / 2,
                y: normalizedCenter.y * scrollView.contentSize.height - viewport.height / 2
            )
            scrollView.setContentOffset(clampedOffset(offset), animated: false)
        } else {
            scrollView.setContentOffset(
                CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top),
                animated: false
            )
        }
        resetsZoom = false
        updateAccessibilityValue()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvas
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
        updateAccessibilityValue()
    }

    private func fittedImageSize(in viewport: CGSize) -> CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            let side = min(viewport.width, viewport.height) * 0.72
            return CGSize(width: side, height: side)
        }
        let scale = min(viewport.width / image.size.width, viewport.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func centerCanvas() {
        let inset = UIEdgeInsets(
            top: max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0),
            left: max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0),
            bottom: max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0),
            right: max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        )
        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
        }
    }

    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let inset = scrollView.contentInset
        return CGPoint(
            x: min(max(offset.x, -inset.left),
                   max(-inset.left, scrollView.contentSize.width - viewport.width + inset.right)),
            y: min(max(offset.y, -inset.top),
                   max(-inset.top, scrollView.contentSize.height - viewport.height + inset.bottom))
        )
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isDismissing else { return false }
        if gestureRecognizer === dismissPan {
            let velocity = dismissPan.velocity(in: self)
            return scrollView.zoomScale <= 1.001 &&
                !scrollView.isZooming &&
                velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
        }
        return true
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isDismissing else { return }
        resetDismissal(animated: false)
        if scrollView.zoomScale > 1.001 {
            scrollView.setZoomScale(1, animated: !reduceMotion)
        } else {
            zoom(to: 2.5, around: gesture.location(in: canvas))
        }
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        guard !isDismissing else { return }
        let translation = gesture.translation(in: self)
        let distance = max(dismissalStartTranslation.y + translation.y, 0)
        switch gesture.state {
        case .began:
            cancelAnimations()
            dismissalStartTranslation = CGPoint(
                x: scrollView.transform.tx, y: scrollView.transform.ty
            )
        case .changed:
            guard scrollView.zoomScale <= 1.001 else {
                resetDismissal(animated: false)
                return
            }
            if !reduceMotion {
                let progress = min(distance / max(bounds.height, 1), 1)
                let scale = max(1 - progress * 0.25, 0.8)
                scrollView.transform = CGAffineTransform(
                    translationX: dismissalStartTranslation.x + translation.x * 0.15, y: distance
                ).scaledBy(x: scale, y: scale)
                onDragProgress?(min(distance / 240, 1), false)
            }
        case .ended:
            let velocity = gesture.velocity(in: self)
            let threshold = min(140, max(80, bounds.height * 0.18))
            if scrollView.zoomScale <= 1.001 &&
                (distance > threshold || (distance > 24 && velocity.y > 900)) {
                isDismissing = true
                onClose?()
            } else {
                resetDismissal(animated: true)
            }
        case .cancelled, .failed:
            resetDismissal(animated: true)
        default:
            break
        }
    }

    private func resetDismissal(animated: Bool) {
        cancelAnimations()
        onDragProgress?(0, animated && !reduceMotion)
        guard animated, !reduceMotion else {
            scrollView.transform = .identity
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.35, dampingRatio: 0.86) { [weak self] in
            self?.scrollView.transform = .identity
        }
        returnAnimator = animator
        animator.startAnimation()
    }

    func cancelAnimations() {
        guard let animator = returnAnimator else { return }
        let visibleTransform = scrollView.layer.presentation()?.affineTransform()
        animator.stopAnimation(true)
        returnAnimator = nil
        if let visibleTransform {
            scrollView.transform = visibleTransform
        }
    }

    private func zoom(to scale: CGFloat, around point: CGPoint) {
        let target = min(max(scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let size = CGSize(
            width: scrollView.bounds.width / target,
            height: scrollView.bounds.height / target
        )
        scrollView.zoom(
            to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            animated: !reduceMotion
        )
    }

    private func changeZoom(by amount: CGFloat) -> Bool {
        guard !isDismissing else { return false }
        let target = min(max(scrollView.zoomScale + amount, 1), 4)
        guard target != scrollView.zoomScale else { return false }
        resetDismissal(animated: false)
        scrollView.setZoomScale(target, animated: !reduceMotion)
        return true
    }

    private func updateAccessibilityValue() {
        accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
    }

    override func accessibilityIncrement() {
        _ = changeZoom(by: 0.5)
    }

    override func accessibilityDecrement() {
        _ = changeZoom(by: -0.5)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !isDismissing else { return false }
        isDismissing = true
        onClose?()
        return true
    }

    @objc private func handleAvatarZoomIn() -> Bool {
        changeZoom(by: 0.5)
    }

    @objc private func handleAvatarZoomOut() -> Bool {
        changeZoom(by: -0.5)
    }

    @objc private func handleAvatarResetZoom() -> Bool {
        guard !isDismissing else { return false }
        resetDismissal(animated: false)
        scrollView.setZoomScale(1, animated: !reduceMotion)
        return true
    }
}

/// viewDidAppear runs after the containing full-screen presentation has appeared,
/// so its source can be restored without changing the image during the zoom.
@MainActor
private struct AccountAvatarPresentationObserver: UIViewControllerRepresentable {
    let onPresented: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.onPresented = onPresented
        return controller
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.onPresented = onPresented
    }

    final class ObserverController: UIViewController {
        var onPresented: (() -> Void)?
        private var hasAppeared = false

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasAppeared else { return }
            hasAppeared = true
            onPresented?()
        }
    }
}
