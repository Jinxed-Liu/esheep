import SwiftUI
import UIKit

enum CompatibilitySymbol {
    static func name(_ preferred: String, fallback: String) -> String {
        UIImage(systemName: preferred) == nil ? fallback : preferred
    }
}

/// Keep the current system appearance while providing usable iOS 17 surfaces.
extension View {
    @ViewBuilder
    func compatibilityListSectionMargins(_ edges: Edge.Set, _ length: CGFloat) -> some View {
        if #available(iOS 26, *) {
            listSectionMargins(edges, length)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibilityToolbarVisibility(_ visibility: Visibility, for placement: ToolbarPlacement) -> some View {
        if #available(iOS 18, *) {
            toolbarVisibility(visibility, for: placement)
        } else {
            toolbar(visibility, for: placement)
        }
    }

    @ViewBuilder
    func compatibilityToolbarBackgroundVisibility(_ visibility: Visibility, for placement: ToolbarPlacement) -> some View {
        if #available(iOS 18, *) {
            toolbarBackgroundVisibility(visibility, for: placement)
        } else {
            toolbarBackground(visibility, for: placement)
        }
    }

    @ViewBuilder
    func compatibilityGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        if #available(iOS 26, *) {
            if clear {
                glassEffect(interactive ? .clear.interactive() : .clear, in: shape)
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func compatibilityGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func compatibilitySafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    @ViewBuilder
    func compatibilityScrollEdgeHidden(_ hidden: Bool, for edges: Edge.Set) -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectHidden(hidden, for: edges)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibilityScrollEdgeStyleSoft(for edges: Edge.Set) -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

struct CompatibilityGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
