import Observation
import SwiftUI
import UIKit

/// Frames use the owning window's coordinates, never process-global screen bounds.
@MainActor
struct AccountAvatarTransitionSource {
    let frameInWindow: CGRect
    let image: UIImage
    let cornerRadius: CGFloat
    weak var window: UIWindow?

    init(
        frameInWindow: CGRect,
        image: UIImage,
        cornerRadius: CGFloat,
        window: UIWindow? = nil
    ) {
        self.frameInWindow = frameInWindow
        self.image = image
        self.cornerRadius = cornerRadius
        self.window = window
    }

    var isValid: Bool {
        frameInWindow.minX.isFinite && frameInWindow.minY.isFinite &&
            frameInWindow.width.isFinite && frameInWindow.height.isFinite &&
            frameInWindow.width > 0 && frameInWindow.height > 0 &&
            cornerRadius.isFinite && cornerRadius >= 0 &&
            image.size.width.isFinite && image.size.height.isFinite &&
            image.size.width > 0 && image.size.height > 0
    }

    func frame(in view: UIView) -> CGRect {
        view.convert(frameInWindow, from: window ?? view.window)
    }
}

/// A small imperative bridge for the actual UIKit photo. Only backdrop/control
/// opacity and interaction availability invalidate SwiftUI.
@MainActor
@Observable
final class AccountAvatarViewerTransitionState {
    var chromeOpacity: Double = 0
    var allowsInteraction = false

    @ObservationIgnored private(set) var photoOpacity: CGFloat = 0
    @ObservationIgnored private weak var owner: UIView?
    @ObservationIgnored private var sourceProvider: (@MainActor () -> AccountAvatarTransitionSource?)?
    @ObservationIgnored private var centerProvider: (@MainActor () -> CGPoint?)?
    @ObservationIgnored private var sizeProvider: (@MainActor () -> CGSize?)?
    @ObservationIgnored private var opacitySetter: (@MainActor (CGFloat) -> Void)?
    @ObservationIgnored private var transformSetter: (@MainActor (CGAffineTransform) -> Void)?
    @ObservationIgnored private var cornerSetter: (@MainActor (CGFloat, TimeInterval) -> Void)?
    @ObservationIgnored private var prepareLayout: (@MainActor () -> Void)?

    func install(
        owner: UIView,
        source: @escaping @MainActor () -> AccountAvatarTransitionSource?,
        center: @escaping @MainActor () -> CGPoint?,
        size: @escaping @MainActor () -> CGSize?,
        setOpacity: @escaping @MainActor (CGFloat) -> Void,
        setTransform: @escaping @MainActor (CGAffineTransform) -> Void,
        setCorner: @escaping @MainActor (CGFloat, TimeInterval) -> Void,
        prepare: @escaping @MainActor () -> Void
    ) {
        self.owner = owner
        sourceProvider = source
        centerProvider = center
        sizeProvider = size
        opacitySetter = setOpacity
        transformSetter = setTransform
        cornerSetter = setCorner
        prepareLayout = prepare
    }

    func uninstall(owner: UIView) {
        guard self.owner === owner else { return }
        self.owner = nil
        sourceProvider = nil
        centerProvider = nil
        sizeProvider = nil
        opacitySetter = nil
        transformSetter = nil
        cornerSetter = nil
        prepareLayout = nil
    }

    func prepare() {
        prepareLayout?()
    }

    var photoSource: AccountAvatarTransitionSource? {
        sourceProvider?()
    }

    var photoCenterInWindow: CGPoint? {
        centerProvider?()
    }

    var photoBaseSize: CGSize? {
        sizeProvider?()
    }

    func setPhotoOpacity(_ opacity: CGFloat) {
        photoOpacity = opacity
        opacitySetter?(opacity)
    }

    func setPhotoTransform(_ transform: CGAffineTransform) {
        transformSetter?(transform)
    }

    func setPhotoCornerRadius(_ radius: CGFloat, duration: TimeInterval = 0) {
        cornerSetter?(radius, duration)
    }
}

/// Mount this as a zero-size settings background. UIKit owns only the gallery
/// presentation; settings navigation and the account model remain SwiftUI-owned.
@MainActor
struct AccountAvatarGalleryPresenter: UIViewControllerRepresentable {
    let isPresented: Bool
    let account: AccountProfile
    let reduceMotion: Bool
    var initialImage: UIImage? = nil
    var initialDigest: String? = nil
    let sourceProvider: @MainActor () -> AccountAvatarTransitionSource?
    let onSourceVisibilityChange: @MainActor (Bool) -> Void
    let onPresented: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    let onEdit: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIViewController(context: Context) -> AnchorController {
        let controller = AnchorController()
        context.coordinator.anchor = controller
        controller.onReady = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleReconcile()
        }
        return controller
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.scheduleReconcile()
    }

    static func dismantleUIViewController(_ controller: AnchorController, coordinator: Coordinator) {
        controller.onReady = nil
        coordinator.invalidate()
    }

    final class AnchorController: UIViewController {
        var onReady: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onReady?()
        }
    }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        var configuration: AccountAvatarGalleryPresenter
        weak var anchor: AnchorController?

        private var hosted: UIHostingController<AccountAvatarViewer>?
        private var transitionState: AccountAvatarViewerTransitionState?
        private var enteringSource: AccountAvatarTransitionSource?
        private var lastValidSource: AccountAvatarTransitionSource?
        private var isTransitioning = false
        private var isInvalidated = false
        private var sourceRetryCount = 0
        private var abortedPresentation = false
        private var hostedAccountID: UUID?
        private var hostedReduceMotion: Bool?
        private var pendingReconcile: Task<Void, Never>?

        init(configuration: AccountAvatarGalleryPresenter) {
            self.configuration = configuration
        }

        func scheduleReconcile() {
            guard !isInvalidated, pendingReconcile == nil else { return }
            pendingReconcile = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.pendingReconcile = nil
                self.reconcile()
            }
        }

        func reconcile() {
            guard !isInvalidated else { return }
            if let source = configuration.sourceProvider(), source.isValid {
                lastValidSource = source
            }
            guard let anchor, anchor.isViewLoaded, anchor.view.window != nil else { return }
            guard !isTransitioning else { return }

            if configuration.isPresented {
                guard !abortedPresentation else { return }
                if let hosted, let transitionState {
                    if hostedAccountID != configuration.account.id ||
                        hostedReduceMotion != configuration.reduceMotion {
                        hosted.rootView = makeViewer(state: transitionState)
                        hostedAccountID = configuration.account.id
                        hostedReduceMotion = configuration.reduceMotion
                    }
                } else {
                    presentGallery(from: anchor)
                }
            } else {
                abortedPresentation = false
                sourceRetryCount = 0
                pendingReconcile?.cancel()
                pendingReconcile = nil
                if let hosted {
                    dismissGallery(hosted)
                }
            }
        }

        private func makeViewer(state: AccountAvatarViewerTransitionState) -> AccountAvatarViewer {
            let source = enteringSource
            let digest = currentAvatarDigest
            // A previous avatar's thumbnail must not replace the current
            // renderer snapshot while the new thumbnail is still decoding.
            let hasMatchingPreview = configuration.initialDigest == digest &&
                configuration.initialImage != nil
            let seed = hasMatchingPreview ? configuration.initialImage : source?.image
            return AccountAvatarViewer(
                account: configuration.account,
                reduceMotion: configuration.reduceMotion,
                initialImage: seed,
                initialDigest: digest,
                transitionState: state,
                onClose: { [weak self] in self?.configuration.onClose() },
                onEdit: { [weak self] in self?.configuration.onEdit() }
            )
        }

        private var currentAvatarDigest: String {
            let account = configuration.account
            return account.avatarCloudDigest ??
                "account-avatar|\(account.id.uuidString)|\(account.updatedAt.timeIntervalSince1970)|\(account.avatarImageData?.count ?? 0)"
        }

        private func presentGallery(from anchor: AnchorController) {
            let current = configuration.sourceProvider()
            let source = current?.isValid == true ? current : lastValidSource
            guard let source, source.isValid else {
                // Wait for the renderer to attach, rather than inventing a
                // screen-center rectangle unrelated to the visible avatar.
                guard sourceRetryCount < 3 else {
                    abortedPresentation = true
                    configuration.onClose()
                    configuration.onDismiss()
                    return
                }
                sourceRetryCount += 1
                scheduleReconcile()
                return
            }
            guard anchor.presentedViewController == nil else { return }

            enteringSource = source
            sourceRetryCount = 0
            let state = AccountAvatarViewerTransitionState()
            let host = UIHostingController(rootView: makeViewer(state: state))
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .custom
            host.transitioningDelegate = self
            host.isModalInPresentation = true
            transitionState = state
            hosted = host
            hostedAccountID = configuration.account.id
            hostedReduceMotion = configuration.reduceMotion
            isTransitioning = true
            configuration.onSourceVisibilityChange(true)

            anchor.present(host, animated: true) { [weak self, weak host] in
                guard let self, let host, self.hosted === host else { return }
                self.isTransitioning = false
                self.transitionState?.allowsInteraction = self.configuration.isPresented
                if self.configuration.isPresented {
                    self.configuration.onPresented()
                }
                self.reconcile()
            }
        }

        private func dismissGallery(_ host: UIHostingController<AccountAvatarViewer>) {
            guard !host.isBeingDismissed else { return }
            isTransitioning = true
            transitionState?.allowsInteraction = false
            host.dismiss(animated: true) { [weak self, weak host] in
                guard let self, let host, self.hosted === host else { return }
                self.finishDismissal()
            }
        }

        private func finishDismissal() {
            guard hosted != nil else { return }
            hosted = nil
            hostedAccountID = nil
            hostedReduceMotion = nil
            transitionState = nil
            enteringSource = nil
            isTransitioning = false
            configuration.onSourceVisibilityChange(false)
            configuration.onDismiss()
        }

        func invalidate() {
            guard !isInvalidated else { return }
            isInvalidated = true
            pendingReconcile?.cancel()
            pendingReconcile = nil
            lastValidSource = nil
            guard let hosted else {
                enteringSource = nil
                return
            }
            // Keep cleanup alive after SwiftUI dismantles its coordinator.
            // Host identity and finishDismissal's guard make this idempotent
            // when normal dismissal is already in flight.
            hosted.dismiss(animated: false) { [self] in
                guard self.hosted === hosted else { return }
                finishDismissal()
            }
        }

        func presentationController(
            forPresented presented: UIViewController,
            presenting: UIViewController?,
            source: UIViewController
        ) -> UIPresentationController? {
            AccountAvatarGalleryPresentationController(
                presentedViewController: presented,
                presenting: presenting
            )
        }

        func animationController(
            forPresented presented: UIViewController,
            presenting: UIViewController,
            source: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            guard let transitionState else { return nil }
            return AccountAvatarGalleryAnimator(
                isPresenting: true,
                reduceMotion: configuration.reduceMotion,
                state: transitionState,
                enteringSource: enteringSource,
                returnSourceProvider: { [weak self] in self?.configuration.sourceProvider() }
            )
        }

        func animationController(
            forDismissed dismissed: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            guard let transitionState else { return nil }
            return AccountAvatarGalleryAnimator(
                isPresenting: false,
                reduceMotion: configuration.reduceMotion,
                state: transitionState,
                enteringSource: nil,
                returnSourceProvider: { [weak self] in self?.configuration.sourceProvider() }
            )
        }
    }
}

@MainActor
private final class AccountAvatarGalleryPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? .zero
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
        containerView?.backgroundColor = .clear
    }
}

@MainActor
private final class AccountAvatarGalleryAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let reduceMotion: Bool
    private let state: AccountAvatarViewerTransitionState
    private let enteringSource: AccountAvatarTransitionSource?
    private let returnSourceProvider: @MainActor () -> AccountAvatarTransitionSource?
    private var geometryAnimator: UIViewPropertyAnimator?

    init(
        isPresenting: Bool,
        reduceMotion: Bool,
        state: AccountAvatarViewerTransitionState,
        enteringSource: AccountAvatarTransitionSource?,
        returnSourceProvider: @escaping @MainActor () -> AccountAvatarTransitionSource?
    ) {
        self.isPresenting = isPresenting
        self.reduceMotion = reduceMotion
        self.state = state
        self.enteringSource = enteringSource
        self.returnSourceProvider = returnSourceProvider
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        reduceMotion ? 0.15 : 0.25
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewKey = isPresenting ? .to : .from
        guard let view = context.view(forKey: key) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        if isPresenting {
            container.addSubview(view)
            if let controller = context.viewController(forKey: .to) {
                view.frame = context.finalFrame(for: controller)
            }
            if view.bounds.isEmpty {
                view.frame = container.bounds
            }
        }
        view.layoutIfNeeded()
        state.prepare()

        guard !reduceMotion else {
            fade(using: context)
            return
        }
        if isPresenting {
            animateIn(view: view, container: container, context: context)
        } else {
            animateOut(view: view, container: container, context: context)
        }
    }

    private func animateIn(
        view: UIView,
        container: UIView,
        context: any UIViewControllerContextTransitioning
    ) {
        guard let source = enteringSource, source.isValid else {
            fade(using: context)
            return
        }
        let photo = state.photoSource
        let sourceFrame = source.frame(in: container)
        let photoFrame = photo?.frame(in: container) ??
            fittedFrame(image: source.image, in: view.convert(view.bounds, to: container))
        guard !sourceFrame.isEmpty, !photoFrame.isEmpty else {
            fade(using: context)
            return
        }
        let center = transitionCenter(in: container, photo: photo, fallback: photoFrame)
        let transform = mappedTransform(from: photoFrame, to: sourceFrame, center: center)
        state.setPhotoTransform(transform)
        state.setPhotoOpacity(0)
        let baseWidth = state.photoBaseSize?.width ?? photoFrame.width
        state.setPhotoCornerRadius(source.cornerRadius * baseWidth / sourceFrame.width)

        // The source retains its aspect-fill crop; a separate whole-photo copy
        // sits beneath it while the real photo follows the same geometry track.
        let sourceCopy = snapshot(image: croppedImage(for: source), frame: sourceFrame, mode: .scaleToFill)
        let wholeCopy = snapshot(image: photo?.image ?? source.image, frame: sourceFrame, mode: .scaleAspectFit)
        sourceCopy.layer.cornerRadius = source.cornerRadius
        wholeCopy.layer.cornerRadius = source.cornerRadius
        container.addSubview(wholeCopy)
        container.addSubview(sourceCopy)

        animateCorner(sourceCopy.layer, to: 0, duration: 0.18)
        animateCorner(wholeCopy.layer, to: 0, duration: 0.18)
        state.setPhotoCornerRadius(0, duration: 0.18)
        withAnimation(.linear(duration: 0.2)) {
            state.chromeOpacity = 1
        }
        UIView.animate(withDuration: 0.07, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.state.setPhotoOpacity(1)
        }

        runGeometry(
            animations: {
                self.state.setPhotoTransform(.identity)
                sourceCopy.frame = photoFrame
                wholeCopy.frame = photoFrame
                sourceCopy.alpha = 0
                wholeCopy.alpha = 0
            },
            completion: {
                sourceCopy.removeFromSuperview()
                wholeCopy.removeFromSuperview()
                self.state.setPhotoTransform(.identity)
                self.state.setPhotoCornerRadius(0)
                self.state.setPhotoOpacity(1)
                context.completeTransition(!context.transitionWasCancelled)
            }
        )
    }

    private func animateOut(
        view: UIView,
        container: UIView,
        context: any UIViewControllerContextTransitioning
    ) {
        // Never return to the cached entrance square. The settings renderer has
        // already restored its circular avatar and may have moved or rotated.
        guard let target = returnSourceProvider(), target.isValid,
              let photo = state.photoSource, photo.isValid else {
            fade(using: context)
            return
        }
        let initialFrame = photo.frame(in: container)
        let targetFrame = target.frame(in: container)
        guard !initialFrame.isEmpty, !targetFrame.isEmpty else {
            fade(using: context)
            return
        }
        let center = transitionCenter(in: container, photo: photo, fallback: initialFrame)
        let transform = mappedTransform(from: initialFrame, to: targetFrame, center: center)
        let departingCopy = snapshot(image: photo.image, frame: initialFrame, mode: .scaleAspectFit)
        let returningCopy = snapshot(image: croppedImage(for: target), frame: initialFrame, mode: .scaleToFill)
        departingCopy.layer.cornerRadius = photo.cornerRadius
        returningCopy.layer.cornerRadius = photo.cornerRadius
        returningCopy.alpha = 0
        container.addSubview(departingCopy)
        container.addSubview(returningCopy)

        animateCorner(departingCopy.layer, to: target.cornerRadius, duration: 0.18)
        animateCorner(returningCopy.layer, to: target.cornerRadius, duration: 0.18)
        let baseWidth = state.photoBaseSize?.width ?? initialFrame.width
        state.setPhotoCornerRadius(
            target.cornerRadius * baseWidth / targetFrame.width,
            duration: 0.18
        )
        withAnimation(.linear(duration: 0.2)) {
            state.chromeOpacity = 0
        }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            returningCopy.alpha = 1
        }

        runGeometry(
            animations: {
                self.state.setPhotoTransform(transform)
                self.state.setPhotoOpacity(0)
                departingCopy.frame = targetFrame
                returningCopy.frame = targetFrame
                departingCopy.alpha = 0
            },
            completion: {
                // All geometry, the 0.18s corner track and 0.1s source handoff
                // have completed before UIKit's dismissal completion is emitted.
                departingCopy.removeFromSuperview()
                returningCopy.removeFromSuperview()
                context.completeTransition(!context.transitionWasCancelled)
            }
        )
    }

    private func fade(using context: any UIViewControllerContextTransitioning) {
        let target = isPresenting ? 1.0 : 0.0
        withAnimation(.linear(duration: 0.15)) {
            state.chromeOpacity = target
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.state.setPhotoOpacity(CGFloat(target))
        } completion: { _ in
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    private func runGeometry(
        animations: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let curve = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.38, y: 0.70),
            controlPoint2: CGPoint(x: 0.125, y: 1)
        )
        let animator = UIViewPropertyAnimator(duration: 0.25, timingParameters: curve)
        geometryAnimator = animator
        animator.addAnimations(animations)
        animator.addCompletion { [weak self] _ in
            self?.geometryAnimator = nil
            completion()
        }
        animator.startAnimation()
    }

    private func transitionCenter(
        in container: UIView,
        photo: AccountAvatarTransitionSource?,
        fallback: CGRect
    ) -> CGPoint {
        guard let center = state.photoCenterInWindow else {
            return CGPoint(x: fallback.midX, y: fallback.midY)
        }
        return container.convert(center, from: photo?.window ?? container.window)
    }

    private func mappedTransform(from start: CGRect, to end: CGRect, center: CGPoint) -> CGAffineTransform {
        let sx = end.width / start.width
        let sy = end.height / start.height
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy,
            tx: end.midX - center.x - (start.midX - center.x) * sx,
            ty: end.midY - center.y - (start.midY - center.y) * sy
        )
    }

    private func fittedFrame(image: UIImage, in viewport: CGRect) -> CGRect {
        let ratio = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return CGRect(
            x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    private func croppedImage(for source: AccountAvatarTransitionSource) -> UIImage {
        // Freeze the source's aspect-fill crop. Resizing the snapshot later
        // scales these pixels instead of recalculating UIImageView's crop.
        let bounds = CGRect(origin: .zero, size: source.frameInWindow.size)
        let scale = max(
            bounds.width / source.image.size.width,
            bounds.height / source.image.size.height
        )
        let imageSize = CGSize(
            width: source.image.size.width * scale,
            height: source.image.size.height * scale
        )
        let imageFrame = CGRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width, height: imageSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, source.window?.traitCollection.displayScale ?? source.image.scale)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            source.image.draw(in: imageFrame)
        }
    }

    private func snapshot(image: UIImage, frame: CGRect, mode: UIView.ContentMode) -> UIImageView {
        let view = UIImageView(image: image)
        view.frame = frame
        view.contentMode = mode
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    private func animateCorner(_ layer: CALayer, to radius: CGFloat, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        animation.toValue = max(radius, 0)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(radius, 0)
        CATransaction.commit()
        layer.add(animation, forKey: "avatar-gallery-corner")
    }
}
