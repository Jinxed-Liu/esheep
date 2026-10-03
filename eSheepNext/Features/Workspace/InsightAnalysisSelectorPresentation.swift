import Observation
import SwiftUI
import UIKit

/// A short-lived, non-key window keeps the editor and keyboard in their
/// original scene while the focused selector receives taps above the blur.
/// It is anchored to the actual composer, never to a process-global screen.
@MainActor
struct InsightAnalysisSelectorPresentation: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var effortIndex: Double
    @Binding var thinkingEnabled: Bool
    @Binding var showReasoning: Bool
    let modelName: String
    var gaugeFrame = CGRect.zero
    var contextIsPresented: Binding<Bool>? = nil
    var contextUsage: InsightContextWindowUsage? = nil
    var contextFrame = CGRect.zero

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeUIViewController(context: Context) -> AnchorController {
        let anchor = AnchorController()
        context.coordinator.anchor = anchor
        anchor.onLayout = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        anchor.onDisappear = { [weak coordinator = context.coordinator] in coordinator?.dismiss(restoreEditor: false) }
        return anchor
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.reconcile()
    }

    static func dismantleUIViewController(_ controller: AnchorController, coordinator: Coordinator) {
        controller.onLayout = nil
        controller.onDisappear = nil
        coordinator.dismiss(restoreEditor: false)
    }

    final class AnchorController: UIViewController {
        var onLayout: (() -> Void)?
        var onDisappear: (() -> Void)?
        private(set) var isVisible = false

        override func loadView() {
            let anchor = UIView()
            anchor.backgroundColor = .clear
            anchor.isUserInteractionEnabled = false
            anchor.accessibilityElementsHidden = true
            view = anchor
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            onLayout?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onLayout?()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            onDisappear?()
        }
    }

    @MainActor @Observable
    final class Layout {
        var anchorBottom: CGFloat = 0
        var composerFrame = CGRect.zero
        var gaugeFrame = CGRect.zero
        var isExpanded = false
    }

    @MainActor final class Coordinator: NSObject {
        var configuration: InsightAnalysisSelectorPresentation
        weak var anchor: AnchorController?
        private weak var ownerWindow: UIWindow?
        private weak var ownerFirstResponder: UIView?
        private weak var observedScene: UIWindowScene?
        private var ownerWasKey = false
        private var ownerAccessibilityHidden = false
        private var overlayWindow: UIWindow?
        private var host: UIHostingController<InsightAnalysisSelectorRoot>?
        private var ownerBlurView: UIVisualEffectView?
        private var ownerBlurIsOpaque: Bool?
        private var isRemovingWindow = false
        private var transitionRevision = 0
        private var isClosing = false
        private var openingDisplayLink: CADisplayLink?
        private var openingFrameCount = 0
        private var presentsContext = false
        private let layout = Layout()

        init(configuration: InsightAnalysisSelectorPresentation) { self.configuration = configuration }

        private var wantsPresentation: Bool {
            configuration.isPresented || configuration.contextIsPresented?.wrappedValue == true
        }

        func reconcile() {
            guard !isRemovingWindow else { return }
            guard wantsPresentation else { closeWindow(); return }
            guard let anchor, anchor.isVisible, let owner = anchor.view.window,
                  let scene = owner.windowScene, scene.activationState == .foregroundActive else { return }
            var ancestor: UIViewController? = anchor
            while let controller = ancestor {
                // Do not put a selector above permissions, file pickers or an
                // unrelated sheet presented by the owning application screen.
                if controller.presentedViewController != nil { dismiss(restoreEditor: false); return }
                ancestor = controller.parent
            }
            if let overlayWindow {
                guard ownerWindow === owner else { dismiss(restoreEditor: false); return }
                presentsContext = configuration.contextIsPresented?.wrappedValue == true
                overlayWindow.frame = owner.frame
                updateAnchor(in: owner)
                updateOwnerBlur()
                host?.rootView = rootView
                if isClosing { expand() }
                return
            }

            ownerWindow = owner
            presentsContext = configuration.contextIsPresented?.wrappedValue == true
            ownerFirstResponder = firstResponder(in: owner)
            ownerWasKey = owner.isKeyWindow
            ownerAccessibilityHidden = owner.accessibilityElementsHidden
            updateAnchor(in: owner)
            installOwnerBlur(in: owner)
            let window = UIWindow(windowScene: scene)
            window.frame = owner.frame
            window.backgroundColor = .clear
            window.isOpaque = false
            // Only inspect windows in the source's own scene. System remote
            // keyboard windows outside this scene remain system-controlled.
            let level = scene.windows.filter { !$0.isHidden && $0.rootViewController != nil && $0 !== window }
                .map(\.windowLevel.rawValue).max() ?? owner.windowLevel.rawValue
            window.windowLevel = UIWindow.Level(rawValue: level + 1)
            let host = UIHostingController(rootView: rootView)
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            self.host = host
            overlayWindow = window
            owner.accessibilityElementsHidden = true
            observedScene = scene
            NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate),
                name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
            // No makeKeyAndVisible: preserve the draft's first responder.
            window.isHidden = false
            // Commit the source pose before retargeting its spring. A main
            // queue callback can run before SwiftUI's first displayed frame,
            // which makes a newly-created window skip its initial scale.
            host.view.layoutIfNeeded()
            openingFrameCount = 0
            let displayLink = CADisplayLink(target: self, selector: #selector(revealAfterSourceFrame(_:)))
            openingDisplayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
            UIAccessibility.post(notification: .screenChanged, argument: host.view)
        }

        private var rootView: InsightAnalysisSelectorRoot {
            InsightAnalysisSelectorRoot(
                layout: layout, effortIndex: configuration.$effortIndex,
                thinkingEnabled: configuration.$thinkingEnabled,
                showReasoning: configuration.$showReasoning,
                modelName: configuration.modelName,
                contextUsage: presentsContext ? configuration.contextUsage : nil,
                onDismiss: { [weak self] in self?.dismiss() },
                onReopen: { [weak self] in
                    guard let self else { return }
                    if self.presentsContext {
                        self.configuration.contextIsPresented?.wrappedValue = true
                    } else {
                        self.configuration.isPresented = true
                    }
                    self.reconcile()
                }
            )
        }

        private func updateAnchor(in owner: UIWindow) {
            guard let anchor else { return }
            let bounds = anchor.view.convert(anchor.view.bounds, to: owner)
            // The focused panel occupies the blurred composer area, with its
            // bottom just above the keyboard. Follow the actual composer in
            // its owning window without another keyboard/safe-area offset.
            layout.anchorBottom = bounds.maxY - 6
            layout.composerFrame = bounds
            let source = presentsContext ? configuration.contextFrame : configuration.gaugeFrame
            layout.gaugeFrame = source.isEmpty ? .zero : anchor.view.convert(source, to: owner)
        }

        @objc private func sceneWillDeactivate() { dismiss(restoreEditor: false) }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) { return responder }
            }
            return nil
        }

        private func installOwnerBlur(in owner: UIWindow) {
            // A blur in another UIWindow cannot reliably sample the original
            // chat. Add the live effect as a sibling of its root hosting view
            // in the owning window; UIHostingController.view owns its children.
            // The remote system keyboard remains outside this view tree.
            let blur = UIVisualEffectView()
            blur.alpha = 0
            blur.isUserInteractionEnabled = false
            blur.accessibilityElementsHidden = true
            owner.addSubview(blur)
            ownerBlurView = blur
            updateOwnerBlur()
        }

        @objc private func transparencyChanged() { updateOwnerBlur() }

        private func updateOwnerBlur() {
            guard let blur = ownerBlurView else { return }
            let opaque = UIAccessibility.isReduceTransparencyEnabled
            if ownerBlurIsOpaque != opaque {
                blur.effect = opaque ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
                blur.backgroundColor = opaque ? .systemBackground : .clear
                ownerBlurIsOpaque = opaque
            }
            // Sample the original editor area and a short upper feather.
            // The rest of the transcript and the keyboard stay uncovered.
            let bottom = min(layout.composerFrame.maxY + 4, blur.superview?.bounds.maxY ?? layout.composerFrame.maxY)
            let top = max(0, min(layout.composerFrame.minY, layout.anchorBottom - 136) - 18)
            blur.frame = CGRect(x: 0, y: top, width: blur.superview?.bounds.width ?? 0, height: max(0, bottom - top))
            let mask = CAGradientLayer()
            mask.frame = blur.bounds
            mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
            mask.locations = [0, NSNumber(value: Double(min(1, 24 / max(1, blur.bounds.height)))), 1]
            blur.layer.mask = mask
            blur.superview?.bringSubviewToFront(blur)
        }

        func dismiss(restoreEditor: Bool = true) {
            if configuration.isPresented { configuration.isPresented = false }
            configuration.contextIsPresented?.wrappedValue = false
            if restoreEditor { closeWindow() }
            else {
                transitionRevision += 1
                layout.isExpanded = false
                removeWindow(restoreEditor: false)
            }
        }

        private var transitionAnimation: Animation {
            UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.14) : .spring(response: 0.34, dampingFraction: 1)
        }

        private func expand() {
            cancelPendingOpening()
            transitionRevision += 1
            isClosing = false
            withAnimation(transitionAnimation) { layout.isExpanded = true }
            UIView.animate(withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.ownerBlurView?.alpha = 1
            }
        }

        private func closeWindow() {
            cancelPendingOpening()
            guard overlayWindow != nil, !isClosing else { return }
            isClosing = true
            transitionRevision += 1
            let revision = transitionRevision
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.ownerBlurView?.alpha = 0
            }
            withAnimation(transitionAnimation, completionCriteria: .removed) {
                layout.isExpanded = false
            } completion: { [weak self] in
                guard let self, revision == self.transitionRevision, !self.wantsPresentation else { return }
                self.removeWindow()
            }
        }

        private func ownerHasPresentedModal(_ owner: UIWindow) -> Bool {
            var ancestor: UIViewController? = anchor
            while let controller = ancestor {
                if controller.presentedViewController != nil { return true }
                ancestor = controller.parent
            }
            return owner.rootViewController?.presentedViewController != nil
        }

        private func removeWindow(restoreEditor: Bool = true) {
            cancelPendingOpening()
            guard let window = overlayWindow, !isRemovingWindow else { return }
            isRemovingWindow = true
            NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: observedScene)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
            let owner = ownerWindow
            let editor = ownerFirstResponder
            let restoreOwnerKey = ownerWasKey
            let originalAccessibilityHidden = ownerAccessibilityHidden
            let presenter = host
            let dismissesAdvanced = presenter?.presentedViewController != nil
            let restoreFocus: @MainActor () -> Void = { [weak self, weak owner, weak editor] in
                guard restoreEditor, let self, let owner,
                      self.overlayWindow == nil, self.anchor?.isVisible == true,
                      !owner.isHidden, owner.windowScene?.activationState == .foregroundActive,
                      self.anchor?.view.window === owner,
                      !self.ownerHasPresentedModal(owner) else { return }
                if restoreOwnerKey { owner.makeKey() }
                // Restore the same UIKit editor. FocusState may still be true
                // after the advanced sheet has resigned its first responder.
                if let editor, editor.window === owner, editor.canBecomeFirstResponder {
                    editor.becomeFirstResponder()
                }
            }
            // A presented advanced sheet can resign the original editor.
            // Restore it after UIKit finishes that dismissal, not midway.
            // Retain this short-lived coordinator until the sheet is gone so
            // dismantling its SwiftUI anchor cannot leave an orphaned blur.
            let finishRemoval: @MainActor () -> Void = { [self, weak owner] in
                window.isHidden = true
                window.rootViewController = nil
                owner?.accessibilityElementsHidden = originalAccessibilityHidden
                ownerBlurView?.removeFromSuperview()
                ownerBlurView = nil
                ownerBlurIsOpaque = nil
                window.windowScene = nil
                host = nil
                overlayWindow = nil
                observedScene = nil
                ownerWindow = nil
                ownerFirstResponder = nil
                isRemovingWindow = false
                isClosing = false
                layout.isExpanded = false
                restoreFocus()
                UIAccessibility.post(notification: .screenChanged, argument: nil)
                // UIKit sheet dismissal may have deferred a fresh opening.
                // Reconcile that intent only in the still-visible scene.
                if wantsPresentation, anchor?.isVisible == true,
                   let owner, owner.windowScene?.activationState == .foregroundActive,
                   anchor?.view.window === owner, !ownerHasPresentedModal(owner) {
                    reconcile()
                }
            }
            if dismissesAdvanced {
                presenter?.dismiss(animated: false, completion: finishRemoval)
            } else {
                finishRemoval()
            }
        }

        @objc private func revealAfterSourceFrame(_ displayLink: CADisplayLink) {
            openingFrameCount += 1
            guard openingFrameCount >= 2 else { return }
            cancelPendingOpening()
            guard wantsPresentation, overlayWindow != nil, !isRemovingWindow,
                  anchor?.isVisible == true,
                  ownerWindow?.windowScene?.activationState == .foregroundActive else { return }
            expand()
        }

        private func cancelPendingOpening() {
            openingDisplayLink?.invalidate()
            openingDisplayLink = nil
        }
    }
}

private struct InsightAnalysisSelectorRoot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let layout: InsightAnalysisSelectorPresentation.Layout
    @Binding var effortIndex: Double
    @Binding var thinkingEnabled: Bool
    @Binding var showReasoning: Bool
    let modelName: String
    let contextUsage: InsightContextWindowUsage?
    let onDismiss: () -> Void
    let onReopen: () -> Void
    @State private var selectorHeight: CGFloat = 136

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = max(1, min(640, geometry.size.width - 60))
            let targetY = max(geometry.safeAreaInsets.top + selectorHeight / 2,
                min(layout.anchorBottom - selectorHeight / 2,
                    geometry.size.height - geometry.safeAreaInsets.bottom - selectorHeight / 2))
            let source = layout.gaugeFrame
            let sourceX = source.isEmpty ? geometry.size.width / 2 : source.midX
            let sourceY = source.isEmpty ? layout.anchorBottom - 22 : source.midY
            ZStack {
                Button(action: onDismiss) {
                    Rectangle().fill(.clear)
                    .contentShape(.rect)
                    .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(contextUsage == nil ? "关闭分析强度选择器" : "关闭上下文用量")
                .accessibilityIdentifier(contextUsage == nil ? "insight.analysis.dismiss" : "insight.context.dismiss")

                focusedPanel
                .frame(width: panelWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { selectorHeight = $0 }
                .scaleEffect(
                    x: layout.isExpanded || reduceMotion ? 1 : 44 / panelWidth,
                    y: layout.isExpanded || reduceMotion ? 1 : 44 / selectorHeight
                )
                .opacity(layout.isExpanded ? 1 : 0)
                .position(
                    x: layout.isExpanded || reduceMotion ? geometry.size.width / 2 : sourceX,
                    y: layout.isExpanded || reduceMotion ? targetY : sourceY
                )
                .accessibilitySortPriority(1)
                // A closing spring can be reversed from the same source
                // control without waiting for its window to disappear.
                if !layout.isExpanded {
                    Button(action: onReopen) { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .position(x: sourceX, y: sourceY)
                        .accessibilityLabel(contextUsage == nil ? "重新展开分析强度" : "重新展开上下文用量")
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape, onDismiss)
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    @ViewBuilder
    private var focusedPanel: some View {
        if let contextUsage {
            InsightContextUsageFocusedPanel(usage: contextUsage, modelName: modelName, isExpanded: layout.isExpanded)
        } else {
            InsightAnalysisFocusedSelector(
                effortIndex: $effortIndex, thinkingEnabled: $thinkingEnabled,
                showReasoning: $showReasoning, modelName: modelName, onDismiss: onDismiss,
                isExpanded: layout.isExpanded
            )
        }
    }
}

private struct InsightContextUsageFocusedPanel: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let usage: InsightContextWindowUsage
    let modelName: String
    let isExpanded: Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 5) {
                Text(modelName).fontWeight(.semibold)
                Text("上下文用量").foregroundStyle(.secondary)
            }
            .font(.title3)
            .lineLimit(2)
            .frame(minHeight: 44)
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)

            usageBar
                .padding(12)
                .modifier(InsightContextUsageSurface(opaque: reduceTransparency))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insight.context.panel")
    }

    private var usageBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.025))
            GeometryReader { geometry in
                Capsule().fill(tint.opacity(0.18))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    // Keep the horizontal capsule's radius fixed. Resizing
                    // the shape to a small fraction makes it a vertical pill.
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: geometry.size.width * usage.fraction,
                                   height: geometry.size.height)
                    }
            }
            HStack(spacing: 12) {
                Text("\(usage.percentage)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("已用约 \(tokenText(usage.estimatedTokens))")
                        .font(.subheadline.weight(.medium))
                    Text("窗口 \(tokenText(usage.limitTokens))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 48)
        // This is a read-only meter. It intentionally has no thumb, drag,
        // adjustable action or binding to the model's context-window limit.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上下文窗口用量")
        .accessibilityValue("已使用约 \(usage.estimatedTokens) tokens，窗口 \(usage.limitTokens) tokens，已使用 \(usage.percentage)%")
        .accessibilityIdentifier("insight.context.progress")
    }

    private var tint: Color {
        usage.fraction >= 0.95 ? .red : usage.fraction >= 0.8 ? .orange : .blue
    }

    private func tokenText(_ tokens: Int) -> String {
        guard tokens >= 1_024 else { return "\(tokens)" }
        let value = Double(tokens) / 1_024
        return value >= 100 || value.rounded() == value
            ? "\(Int(value.rounded()))K" : String(format: "%.1fK", value)
    }
}

private struct InsightContextUsageSurface: ViewModifier {
    let opaque: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content.background(Color(uiColor: .secondarySystemBackground), in: .capsule)
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: .capsule)
        }
    }
}
