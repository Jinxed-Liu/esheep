import Observation
import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

/// A temporary, non-key panel in the composer's own scene. It has no popover
/// arrow or global backdrop; the editor and system keyboard keep their window.
@MainActor
struct InsightComposerMenuPresentation<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let sourceFrame: CGRect
    let isBlocked: Bool
    let allowsReopen: Bool
    @ViewBuilder let content: () -> Content
    let onDismissed: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeUIView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        anchor.accessibilityElementsHidden = true
        context.coordinator.anchor = anchor
        anchor.onLayout = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        anchor.onDisappear = { [weak coordinator = context.coordinator] in coordinator?.removeWindow(allowsAction: false) }
        return anchor
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.reconcile()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnchorView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.onLayout = nil
        view.onDisappear = nil
        coordinator.removeWindow(allowsAction: false)
    }

    final class AnchorView: UIView {
        var onLayout: (() -> Void)?
        var onDisappear: (() -> Void)?
        var isVisible: Bool { window != nil && !isHidden }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { onDisappear?() }
            else { onLayout?() }
        }
    }

    @MainActor final class Coordinator: NSObject {
        var configuration: InsightComposerMenuPresentation
        weak var anchor: AnchorView?
        private weak var ownerWindow: UIWindow?
        private weak var editor: UIView?
        private weak var scene: UIWindowScene?
        private var ownerWasKey = false
        private var ownerAccessibilityHidden = false
        private var window: UIWindow?
        private var host: UIHostingController<AnyView>?
        private let layout = InsightComposerMenuLayout()
        private var isClosing = false
        private var isCancellingOpen = false
        private var isReconciling = false
        private var transitionRevision = 0
        private var openingDisplayLink: CADisplayLink?
        private var openingFrames = 0

        #if DEBUG
        private static var diagnosticLogger: Logger {
            Logger(subsystem: "com.sheepfarm.compatibility", category: "attachment-panel")
        }
        private let diagnosticID = UUID()
        private var diagnosticWindowID: UUID?
        #endif

        private func diagnose(_ event: @autoclosure () -> String) {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--design-acceptance") else { return }
            Self.diagnosticLogger.debug("panel[\(self.diagnosticID.uuidString, privacy: .public)] \(event(), privacy: .public)")
            #endif
        }

        private func diagnosticState() -> String {
            let currentScene = scene ?? anchor?.window?.windowScene
            let sceneState = currentScene.map { String(describing: $0.activationState) } ?? "nil"
            var state = "scene=\(sceneState) intent=\(configuration.isPresented) blocked=\(configuration.isBlocked) cancelling=\(isCancellingOpen) reconciling=\(isReconciling) closing=\(isClosing) window=\(window != nil) anchorVisible=\(anchor?.isVisible ?? false) revision=\(transitionRevision)"
            #if DEBUG
            state += " windowID=\(diagnosticWindowID?.uuidString ?? "nil")"
            #endif
            return state
        }

        /// Capture only the logger and trace UUID, so a callback remains visible
        /// in diagnostics even if its coordinator has already been released.
        #if DEBUG
        private func diagnosticCallbackRecorder() -> ((String) -> Void)? {
            guard ProcessInfo.processInfo.arguments.contains("--design-acceptance") else { return nil }
            let logger = Self.diagnosticLogger
            let traceID = diagnosticID.uuidString
            return { event in
                logger.debug("panel[\(traceID, privacy: .public)] \(event, privacy: .public)")
            }
        }
        #endif

        init(configuration: InsightComposerMenuPresentation) { self.configuration = configuration }

        func reconcile() {
            diagnose("reconcile.enter \(diagnosticState())")
            guard !isCancellingOpen, !isReconciling else {
                diagnose("reconcile.skip-reentrant \(diagnosticState())")
                return
            }
            isReconciling = true
            defer {
                isReconciling = false
                diagnose("reconcile.exit \(diagnosticState())")
            }
            guard !configuration.isBlocked else {
                diagnose("reconcile.cancel-blocked \(diagnosticState())")
                removeWindow(allowsAction: false)
                return
            }
            guard configuration.isPresented else {
                diagnose("reconcile.close-intent \(diagnosticState())")
                closeWindow()
                return
            }
            guard let anchor, anchor.isVisible, let owner = anchor.window,
                  !anchor.bounds.isEmpty, let scene = owner.windowScene else {
                diagnose("reconcile.skip-anchor \(diagnosticState())")
                return
            }
            guard scene.activationState == .foregroundActive else {
                diagnose("reconcile.cancel-inactive \(diagnosticState())")
                removeWindow(allowsAction: false)
                return
            }
            guard !ownerHasModal(owner) else {
                diagnose("reconcile.cancel-modal \(diagnosticState())")
                removeWindow(allowsAction: false)
                return
            }
            if let window {
                guard ownerWindow === owner else {
                    diagnose("reconcile.cancel-owner-change \(diagnosticState())")
                    removeWindow(allowsAction: false)
                    return
                }
                diagnose("reconcile.existing \(diagnosticState())")
                window.frame = owner.frame
                window.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
                updateAnchor(in: owner)
                host?.rootView = rootView
                if isClosing { expand() }
                return
            }

            ownerWindow = owner
            editor = firstResponder(in: owner)
            ownerWasKey = owner.isKeyWindow
            ownerAccessibilityHidden = owner.accessibilityElementsHidden
            self.scene = scene
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--design-acceptance") { diagnosticWindowID = UUID() }
            #endif
            diagnose("window.open.begin \(diagnosticState())")
            updateAnchor(in: owner)
            let window = UIWindow(windowScene: scene)
            window.frame = owner.frame
            window.backgroundColor = .clear
            window.isOpaque = false
            window.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
            let level = scene.windows.filter { !$0.isHidden && $0.rootViewController != nil && $0 !== window }
                .map(\.windowLevel.rawValue).max() ?? owner.windowLevel.rawValue
            window.windowLevel = UIWindow.Level(rawValue: level + 1)
            let host = UIHostingController(rootView: rootView)
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            self.host = host
            self.window = window
            owner.accessibilityElementsHidden = true
            NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate),
                name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged),
                name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            // Showing a non-key window preserves the original editor.
            window.isHidden = false
            diagnose("window.open.shown ownerKey=\(owner.isKeyWindow) overlayKey=\(window.isKeyWindow) \(diagnosticState())")
            host.view.layoutIfNeeded()
            openingFrames = 0
            let link = CADisplayLink(target: self, selector: #selector(revealAfterSourceFrame(_:)))
            openingDisplayLink = link
            link.add(to: .main, forMode: .common)
            UIAccessibility.post(notification: .screenChanged, argument: host.view)
        }

        private var rootView: AnyView {
            AnyView(InsightComposerMenuRoot(layout: layout, content: configuration.content(),
                allowsReopen: configuration.allowsReopen,
                onDismiss: { [weak self] in self?.configuration.isPresented = false; self?.closeWindow() },
                onReopen: { [weak self] in
                    guard let self, self.configuration.allowsReopen, !self.configuration.isBlocked else { return }
                    self.configuration.isPresented = true
                    self.expand()
                }))
        }

        private func updateAnchor(in owner: UIWindow) {
            guard let anchor else { return }
            // A background UIView follows the composer's actual proposal.
            // A child controller's safe-area-adjusted bounds can extend
            // below the keyboard and are not a reliable button anchor.
            layout.topInset = owner.safeAreaInsets.top
            layout.availableBottom = owner.bounds.maxY - owner.safeAreaInsets.bottom
            if let root = owner.rootViewController?.viewIfLoaded {
                let guide = root.keyboardLayoutGuide
                root.layoutIfNeeded()
                let keyboardFrame = root.convert(guide.layoutFrame, to: owner)
                if !keyboardFrame.isEmpty, keyboardFrame.intersects(owner.bounds) {
                    layout.availableBottom = min(layout.availableBottom, keyboardFrame.minY)
                }
            }
            // Resolve the owning view's pending keyboard layout first, then
            // sample the actual composer and its 44pt source in that layout.
            layout.composerFrame = anchor.convert(anchor.bounds, to: owner)
            layout.sourceFrame = anchor.convert(configuration.sourceFrame, to: owner)
        }

        @objc private func keyboardFrameChanged() {
            guard let owner = ownerWindow, owner.isKeyWindow,
                  owner.windowScene?.activationState == .foregroundActive,
                  anchor?.window === owner else { return }
            reconcile()
        }

        private var animation: Animation {
            UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.14) : .spring(response: 0.3, dampingFraction: 1)
        }

        private func expand() {
            diagnose("window.expand \(diagnosticState())")
            cancelOpening()
            transitionRevision += 1
            isClosing = false
            withAnimation(animation) { layout.isExpanded = true }
        }

        private func closeWindow() {
            diagnose("window.close.begin \(diagnosticState())")
            cancelOpening()
            guard window != nil, !isClosing else { return }
            isClosing = true
            transitionRevision += 1
            let revision = transitionRevision
            withAnimation(animation, completionCriteria: .removed) {
                layout.isExpanded = false
            } completion: { [weak self] in
                guard let self else { return }
                self.diagnose("window.close.completion expectedRevision=\(revision) \(self.diagnosticState())")
                guard revision == self.transitionRevision, !self.configuration.isPresented else { return }
                self.removeWindow(allowsAction: true)
            }
        }

        fileprivate func removeWindow(allowsAction: Bool) {
            diagnose("window.remove.begin allowsAction=\(allowsAction) \(diagnosticState())")
            cancelOpening()
            guard let window else {
                // A modal may win the race before the first panel window is
                // installed. Clear that opening intent instead of leaving
                // the composer's pending session stuck behind the modal.
                guard configuration.isPresented, !isCancellingOpen else { return }
                isCancellingOpen = true
                let completion = configuration.onDismissed
                #if DEBUG
                let diagnosticCallback = diagnosticCallbackRecorder()
                #endif
                DispatchQueue.main.async { [weak self] in
                    #if DEBUG
                    diagnosticCallback?("dismiss.callback.before emptyWindow=true allowsAction=false \(self?.diagnosticState() ?? "coordinator=released")")
                    #endif
                    self?.isCancellingOpen = false
                    completion(false)
                    #if DEBUG
                    diagnosticCallback?("dismiss.callback.after emptyWindow=true allowsAction=false \(self?.diagnosticState() ?? "coordinator=released")")
                    #endif
                }
                return
            }
            transitionRevision += 1
            NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            let owner = ownerWindow
            let editor = editor
            let canRestore = allowsAction && !configuration.isBlocked && anchor?.isVisible == true
                && anchor?.window === owner && owner?.windowScene?.activationState == .foregroundActive
                && owner.map({ !ownerHasModal($0) }) == true
            let wasOverlayKey = window.isKeyWindow
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            owner?.accessibilityElementsHidden = ownerAccessibilityHidden
            self.window = nil
            host = nil
            scene = nil
            ownerWindow = nil
            self.editor = nil
            isClosing = false
            layout.isExpanded = false
            diagnose("window.remove.detached canRestore=\(canRestore) \(diagnosticState())")
            if canRestore, let owner {
                if ownerWasKey || wasOverlayKey { owner.makeKey() }
                if let editor, editor.window === owner, editor.canBecomeFirstResponder { editor.becomeFirstResponder() }
            }
            let completion = configuration.onDismissed
            #if DEBUG
            let diagnosticCallback = diagnosticCallbackRecorder()
            // The window is already detached; only now may the owning view
            // present the original camera, Photos or document picker.
            DispatchQueue.main.async { [weak self] in
                diagnosticCallback?("dismiss.callback.before emptyWindow=false allowsAction=\(canRestore) \(self?.diagnosticState() ?? "coordinator=released")")
                completion(canRestore)
                diagnosticCallback?("dismiss.callback.after emptyWindow=false allowsAction=\(canRestore) \(self?.diagnosticState() ?? "coordinator=released")")
            }
            #else
            DispatchQueue.main.async { completion(canRestore) }
            #endif
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        private func ownerHasModal(_ owner: UIWindow) -> Bool {
            var responder: UIResponder? = anchor
            while let current = responder {
                if let controller = current as? UIViewController, controller.presentedViewController != nil { return true }
                responder = current.next
            }
            return owner.rootViewController?.presentedViewController != nil
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) { return responder }
            }
            return nil
        }

        @objc private func sceneWillDeactivate() {
            diagnose("scene.will-deactivate \(diagnosticState())")
            removeWindow(allowsAction: false)
        }

        @objc private func revealAfterSourceFrame(_ link: CADisplayLink) {
            openingFrames += 1
            guard openingFrames >= 2 else { return }
            cancelOpening()
            guard configuration.isPresented, !configuration.isBlocked, window != nil,
                  anchor?.isVisible == true, scene?.activationState == .foregroundActive else { return }
            expand()
        }

        private func cancelOpening() {
            openingDisplayLink?.invalidate()
            openingDisplayLink = nil
        }
    }
}

@MainActor @Observable
private final class InsightComposerMenuLayout {
    var composerFrame = CGRect.zero
    var sourceFrame = CGRect.zero
    var panelHeight: CGFloat = 369
    var topInset: CGFloat = 0
    var availableBottom: CGFloat = 0
    var isExpanded = false
}

private struct InsightComposerMenuRoot<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let layout: InsightComposerMenuLayout
    let content: Content
    let allowsReopen: Bool
    let onDismiss: () -> Void
    let onReopen: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = min(280, max(1, geometry.size.width - 24))
            // A non-key overlay does not receive the original editor's
            // keyboard safe area. Use the original window's keyboard guide.
            let bottom = min(layout.availableBottom - 8, layout.composerFrame.maxY - 6)
            let height = min(layout.panelHeight, max(1, bottom - layout.topInset - 12))
            let left = min(max(12, layout.composerFrame.minX + 20), geometry.size.width - width - 12)
            let source = layout.sourceFrame
            ZStack(alignment: .topLeading) {
                Button(action: onDismiss) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭添加菜单")
                .accessibilityIdentifier("insight.attachment.dismiss")
                ScrollView {
                    content.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.panelHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: width, height: height)
                .modifier(InsightComposerMenuSurface(opaque: reduceTransparency))
                .scaleEffect(x: layout.isExpanded || reduceMotion ? 1 : max(0.01, source.width / width),
                             y: layout.isExpanded || reduceMotion ? 1 : max(0.01, source.height / height))
                .opacity(layout.isExpanded ? 1 : 0)
                .position(x: layout.isExpanded || reduceMotion ? left + width / 2 : source.midX,
                          y: layout.isExpanded || reduceMotion ? bottom - height / 2 : source.midY)
                .allowsHitTesting(layout.isExpanded)
                if !layout.isExpanded && allowsReopen {
                    Button(action: onReopen) { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .frame(width: source.width, height: source.height)
                        .position(x: source.midX, y: source.midY)
                        .accessibilityLabel("重新展开添加菜单")
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct InsightComposerMenuSurface: ViewModifier {
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content.background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 32))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 32))
        } else {
            content.background(.ultraThinMaterial, in: .rect(cornerRadius: 32))
        }
    }
}
