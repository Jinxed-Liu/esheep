import SwiftUI

/// One view hierarchy in both sizes, so card state and presented destinations
/// survive a fold. Column assignments preserve the compact reading order.
struct AdaptiveCardStack<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var division: CardLayoutDivision?
    var spacing: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = AnyLayout(CardColumnLayout(
            allowsColumns: horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize,
            spacing: spacing, division: division
        ))
        layout { content() }
            .onGeometryChange(for: CardLayoutDivision?.self) { geometry in
                // SwiftUI 8.0.85 ships with the 27.1 SDK. Older build hosts
                // retain the same resizable layout without the fold query.
#if canImport(SwiftUI, _version: 8.0.85)
                guard #available(iOS 27.1, *) else { return nil }
                // A horizontal fold is not a break in continuously scrolling
                // content. Query in the layout's own directional coordinates.
                guard let region = geometry.reservedRegions(kind: .division, options: .includeInactive)
                    .first(where: { $0.frame.height > $0.frame.width }) else { return nil }
                return CardLayoutDivision(
                    frame: CGRect(x: region.frame.minX, y: 0, width: region.frame.width, height: region.frame.height),
                    isActive: region.isActive
                )
#else
                return nil
#endif
            } action: { division = $0 }
    }
}

enum CardColumn: Int { case leading, trailing }

private struct CardColumnKey: LayoutValueKey {
    static let defaultValue: CardColumn? = nil
}

extension View {
    func adaptiveCardColumn(_ column: CardColumn) -> some View {
        layoutValue(key: CardColumnKey.self, value: column)
    }
}

struct CardLayoutDivision: Equatable, Sendable {
    let frame: CGRect
    let isActive: Bool
}

/// Values are local to the offered content area, never the device screen.
struct CardColumnWidths: Equatable {
    let leading: CGFloat
    let trailingOrigin: CGFloat
    let trailing: CGFloat

    static func resolve(width: CGFloat, spacing: CGFloat, division: CardLayoutDivision?,
                        minimumColumnWidth: CGFloat = 280) -> Self? {
        let midpoint = width / 2
        var leadingEnd = midpoint - spacing / 2
        var trailingStart = midpoint + spacing / 2
        if let division, division.frame.height > division.frame.width,
           division.frame.midX > 0, division.frame.midX < width {
            // Keep the gutter at the fold, even with asymmetric bar insets.
            // Inactive reserved regions do not consume their active margins.
            let center = division.frame.midX
            leadingEnd = center - spacing / 2
            trailingStart = center + spacing / 2
            if division.isActive {
                // ReservedRegion.frame already includes the system margins.
                leadingEnd = min(leadingEnd, division.frame.minX)
                trailingStart = max(trailingStart, division.frame.maxX)
            }
        }
        guard leadingEnd >= minimumColumnWidth,
              width - trailingStart >= minimumColumnWidth else { return nil }
        return Self(leading: leadingEnd, trailingOrigin: trailingStart, trailing: width - trailingStart)
    }
}

private struct CardColumnLayout: Layout {
    let allowsColumns: Bool
    let spacing: CGFloat
    let division: CardLayoutDivision?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            // SwiftUI mirrors custom Layout coordinates in right-to-left UI.
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = allowsColumns ? CardColumnWidths.resolve(width: width, spacing: spacing, division: division) : nil
        var nextY: [CGFloat] = [0, 0]
        return subviews.map { subview in
            let column = columns == nil ? nil : subview[CardColumnKey.self]
            let x: CGFloat
            let childWidth: CGFloat
            let y: CGFloat
            if let column, let columns {
                x = column == .leading ? 0 : columns.trailingOrigin
                childWidth = column == .leading ? columns.leading : columns.trailing
                y = nextY[column.rawValue]
            } else {
                x = 0
                childWidth = width
                y = nextY.max() ?? 0
            }
            let height = max(0, subview.sizeThatFits(ProposedViewSize(width: childWidth, height: nil)).height)
            let frame = CGRect(x: x, y: y, width: childWidth, height: height)
            if let column { nextY[column.rawValue] = frame.maxY + spacing }
            else { nextY = [frame.maxY + spacing, frame.maxY + spacing] }
            return frame
        }
    }
}
