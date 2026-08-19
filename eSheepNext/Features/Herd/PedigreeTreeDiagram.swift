import SwiftUI

/// 两代只读系谱树。所有节点都来自已经加载完成的 `PedigreeProfileSnapshot`，
/// 不持有 SwiftData 查询，也不参与任何系谱写入。
struct PedigreeTreeDiagram: View {
    let profile: PedigreeProfileSnapshot
    let sireCandidates: [PedigreeSireCandidate]
    let isLoadingCandidates: Bool
    let canConfirmCandidate: Bool
    let onSelectSheep: (PedigreeRelatedSheep) -> Void
    let onSelectCandidate: (PedigreeSireCandidate) -> Void

    private enum Layout {
        static let minimumWidth: CGFloat = 520
        static let height: CGFloat = 236
        static let nodeWidth: CGFloat = 104
        static let regularLitterNodeWidth: CGFloat = 92
        static let compactLitterNodeWidth: CGFloat = 76
        static let nodeHeight: CGFloat = 54
        static let regularLitterSpacing: CGFloat = 100
        static let compactLitterSpacing: CGFloat = 78
        static let grandparentY: CGFloat = 30
        static let parentY: CGFloat = 108
        static let subjectY: CGFloat = 190
    }

    private var usesCompactLitterLayout: Bool { litterNodes.count >= 4 }
    private var litterNodeWidth: CGFloat {
        usesCompactLitterLayout ? Layout.compactLitterNodeWidth : Layout.regularLitterNodeWidth
    }
    private var litterSpacing: CGFloat {
        usesCompactLitterLayout ? Layout.compactLitterSpacing : Layout.regularLitterSpacing
    }

    private var canvasWidth: CGFloat {
        max(Layout.minimumWidth, CGFloat(litterNodes.count) * litterSpacing + 20)
    }

    private var centerX: CGFloat { canvasWidth / 2 }
    private var maternalGranddamX: CGFloat { centerX - 175 }
    private var maternalGrandsireX: CGFloat { centerX - 65 }
    private var paternalGranddamX: CGFloat { centerX + 65 }
    private var paternalGrandsireX: CGFloat { centerX + 175 }
    private var damX: CGFloat { centerX - 120 }
    private var sireX: CGFloat { centerX + 120 }

    private var litterNodeXs: [CGFloat] {
        let width = CGFloat(max(0, litterNodes.count - 1)) * litterSpacing
        let startX = centerX - width / 2
        return litterNodes.indices.map { startX + CGFloat($0) * litterSpacing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    PedigreeTreeConnectors(
                        centerX: centerX,
                        maternalGranddamX: maternalGranddamX,
                        maternalGrandsireX: maternalGrandsireX,
                        paternalGranddamX: paternalGranddamX,
                        paternalGrandsireX: paternalGrandsireX,
                        damX: damX,
                        sireX: sireX,
                        litterXs: litterNodeXs
                    )

                    treeNode(grandparentNode(
                        id: "maternal-granddam",
                        role: "外祖母",
                        sheep: profile.maternalGranddam,
                        expectedSex: .ewe
                    ))
                    .position(x: maternalGranddamX, y: Layout.grandparentY)

                    treeNode(grandparentNode(
                        id: "maternal-grandsire",
                        role: "外祖父",
                        sheep: profile.maternalGrandsire,
                        expectedSex: .ram
                    ))
                    .position(x: maternalGrandsireX, y: Layout.grandparentY)

                    treeNode(grandparentNode(
                        id: "paternal-granddam",
                        role: "祖母",
                        sheep: profile.paternalGranddam,
                        expectedSex: .ewe
                    ))
                    .position(x: paternalGranddamX, y: Layout.grandparentY)

                    treeNode(grandparentNode(
                        id: "paternal-grandsire",
                        role: "祖父",
                        sheep: profile.paternalGrandsire,
                        expectedSex: .ram
                    ))
                    .position(x: paternalGrandsireX, y: Layout.grandparentY)

                    treeNode(parentNode(id: "dam", role: "母本", sheep: profile.dam, expectedSex: .ewe))
                        .position(x: damX, y: Layout.parentY)

                    treeNode(sireNode)
                        .position(x: sireX, y: Layout.parentY)

                    ForEach(Array(litterNodes.enumerated()), id: \.element.id) { index, node in
                        treeNode(node, width: litterNodeWidth)
                            .position(x: litterNodeXs[index], y: Layout.subjectY)
                    }
                }
                .frame(width: canvasWidth, height: Layout.height)
            }
            .defaultScrollAnchor(.center)
            .scrollIndicators(.hidden)
            .id(profile.record.id)

            Label(LocalizedStringKey(interactionHint), systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("两代系谱树")
    }

    private var subjectNode: PedigreeTreeNode {
        .init(
            id: "subject",
            role: "本羊",
            title: profile.record.earTag,
            subtitle: profile.record.sex.displayName,
            systemImage: "circle.circle.fill",
            tint: AppTheme.brand,
            emphasis: .subject,
            action: nil
        )
    }

    private var litterNodes: [PedigreeTreeNode] {
        var nodes = profile.littermates.prefix(5).map {
            sheepNode(id: "littermate-\($0.id.uuidString)", role: "同胎", sheep: $0)
        }
        nodes.insert(subjectNode, at: nodes.count / 2)
        return nodes
    }

    private var interactionHint: String {
        guard !profile.littermates.isEmpty else { return "左右滑动 · 点击节点进入档案" }
        let total = profile.littermates.count + 1
        if profile.littermates.count > 5 {
            return "同胎 \(total) 只 · 图中显示本羊及 5 只同胎羊"
        }
        return "同胎 \(total) 只 · 点击节点进入档案"
    }

    private var sireNode: PedigreeTreeNode {
        if let donor = profile.donor {
            let detail = [donor.registrationNumber.nilIfEmpty, profile.sire.map { "关联 \($0.earTag)" }]
                .compactMap { $0 }
                .joined(separator: " · ")
            return .init(
                id: "sire-donor",
                role: "父本来源",
                title: donor.name,
                subtitle: detail.nilIfEmpty ?? "冻精供体",
                systemImage: "snowflake",
                tint: .cyan,
                emphasis: .normal,
                action: profile.sire.map { sire in { onSelectSheep(sire) } }
            )
        }
        if let sire = profile.sire {
            return sheepNode(id: "sire", role: "父本", sheep: sire)
        }
        if isLoadingCandidates {
            return .init(
                id: "sire-loading",
                role: "父本",
                title: "正在推算",
                subtitle: "核对历史同舍",
                systemImage: "hourglass",
                tint: .secondary,
                emphasis: .placeholder,
                action: nil
            )
        }
        if sireCandidates.count == 1, let candidate = sireCandidates.first {
            return .init(
                id: "sire-candidate-\(candidate.ramID.uuidString)",
                role: "父本候选",
                title: candidate.earTag,
                subtitle: candidate.isPrematurityWindowMatch
                    ? "早产容差 +\(candidate.prematurityAllowanceDays) 天"
                    : "待人工确认",
                systemImage: "questionmark.diamond",
                tint: .orange,
                emphasis: .candidate,
                action: canConfirmCandidate ? { onSelectCandidate(candidate) } : nil
            )
        }
        if sireCandidates.count > 1 {
            return .init(
                id: "sire-candidates",
                role: "父本候选",
                title: "\(sireCandidates.count) 只待确认",
                subtitle: "请在下方人工选择",
                systemImage: "questionmark.diamond",
                tint: .orange,
                emphasis: .candidate,
                action: nil
            )
        }
        return unknownNode(id: "sire-unknown", role: "父本", expectedSex: .ram)
    }

    private func grandparentNode(
        id: String,
        role: String,
        sheep: PedigreeRelatedSheep?,
        expectedSex: SheepSex
    ) -> PedigreeTreeNode {
        parentNode(id: id, role: role, sheep: sheep, expectedSex: expectedSex)
    }

    private func parentNode(
        id: String,
        role: String,
        sheep: PedigreeRelatedSheep?,
        expectedSex: SheepSex
    ) -> PedigreeTreeNode {
        sheep.map { sheepNode(id: id, role: role, sheep: $0) }
            ?? unknownNode(id: id, role: role, expectedSex: expectedSex)
    }

    private func sheepNode(id: String, role: String, sheep: PedigreeRelatedSheep) -> PedigreeTreeNode {
        .init(
            id: id,
            role: role,
            title: sheep.earTag,
            subtitle: sheep.currentPenName,
            systemImage: sheep.sex == .ewe ? "f.circle" : sheep.sex == .ram ? "m.circle" : "circle",
            tint: sheep.sex == .ewe ? .pink : sheep.sex == .ram ? .blue : .secondary,
            emphasis: .normal,
            action: { onSelectSheep(sheep) }
        )
    }

    private func unknownNode(id: String, role: String, expectedSex: SheepSex) -> PedigreeTreeNode {
        .init(
            id: id,
            role: role,
            title: "未知",
            subtitle: nil,
            systemImage: expectedSex == .ewe ? "f.circle.dashed" : "m.circle.dashed",
            tint: .secondary,
            emphasis: .placeholder,
            action: nil
        )
    }

    private func treeNode(_ node: PedigreeTreeNode, width: CGFloat = Layout.nodeWidth) -> some View {
        PedigreeTreeNodeView(
            node: node,
            width: width,
            height: Layout.nodeHeight
        )
    }
}

private struct PedigreeTreeConnectors: View {
    let centerX: CGFloat
    let maternalGranddamX: CGFloat
    let maternalGrandsireX: CGFloat
    let paternalGranddamX: CGFloat
    let paternalGrandsireX: CGFloat
    let damX: CGFloat
    let sireX: CGFloat
    let litterXs: [CGFloat]

    var body: some View {
        Canvas { context, _ in
            let color = Color.secondary.opacity(0.34)
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            connect(
                from: CGPoint(x: maternalGranddamX, y: 57),
                to: CGPoint(x: damX, y: 81),
                context: &context,
                color: color,
                stroke: stroke
            )
            connect(
                from: CGPoint(x: maternalGrandsireX, y: 57),
                to: CGPoint(x: damX, y: 81),
                context: &context,
                color: color,
                stroke: stroke
            )
            connect(
                from: CGPoint(x: paternalGranddamX, y: 57),
                to: CGPoint(x: sireX, y: 81),
                context: &context,
                color: color,
                stroke: stroke
            )
            connect(
                from: CGPoint(x: paternalGrandsireX, y: 57),
                to: CGPoint(x: sireX, y: 81),
                context: &context,
                color: color,
                stroke: stroke
            )
            connect(
                from: CGPoint(x: damX, y: 135),
                to: CGPoint(x: centerX, y: 151),
                context: &context,
                color: color,
                stroke: stroke
            )
            connect(
                from: CGPoint(x: sireX, y: 135),
                to: CGPoint(x: centerX, y: 151),
                context: &context,
                color: color,
                stroke: stroke
            )
            connectLitter(
                from: CGPoint(x: centerX, y: 151),
                toXs: litterXs,
                nodeTopY: 163,
                context: &context,
                color: color,
                stroke: stroke
            )
        }
        .allowsHitTesting(false)
    }

    private func connect(
        from start: CGPoint,
        to end: CGPoint,
        context: inout GraphicsContext,
        color: Color,
        stroke: StrokeStyle
    ) {
        let middleY = start.y + ((end.y - start.y) / 2)
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x, y: middleY))
        path.addLine(to: CGPoint(x: end.x, y: middleY))
        path.addLine(to: end)
        context.stroke(path, with: .color(color), style: stroke)
    }

    private func connectLitter(
        from start: CGPoint,
        toXs: [CGFloat],
        nodeTopY: CGFloat,
        context: inout GraphicsContext,
        color: Color,
        stroke: StrokeStyle
    ) {
        guard let firstX = toXs.first, let lastX = toXs.last else { return }
        let branchY = start.y + 6
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x, y: branchY))
        path.move(to: CGPoint(x: firstX, y: branchY))
        path.addLine(to: CGPoint(x: lastX, y: branchY))
        for x in toXs {
            path.move(to: CGPoint(x: x, y: branchY))
            path.addLine(to: CGPoint(x: x, y: nodeTopY))
        }
        context.stroke(path, with: .color(color), style: stroke)
    }
}

private struct PedigreeTreeNode: Identifiable {
    enum Emphasis {
        case normal
        case subject
        case candidate
        case placeholder
    }

    let id: String
    let role: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let emphasis: Emphasis
    let action: (() -> Void)?
}

private struct PedigreeTreeNodeView: View {
    let node: PedigreeTreeNode
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let action = node.action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开该羊只档案")
            } else {
                content
            }
        }
        .frame(width: width, height: height)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    node.tint.opacity(node.emphasis == .placeholder ? 0.25 : 0.72),
                    style: StrokeStyle(
                        lineWidth: node.emphasis == .subject ? 2 : 1.25,
                        dash: node.emphasis == .candidate ? [5, 4] : []
                    )
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: node.systemImage)
                Text(LocalizedStringKey(node.role))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(node.tint)

            Text(LocalizedStringKey(node.title))
                .font(.caption.weight(node.emphasis == .subject ? .bold : .semibold))
                .foregroundStyle(node.emphasis == .placeholder ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let subtitle = node.subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityLabel: String {
        [node.role, node.title, node.subtitle].compactMap { $0 }.joined(separator: "，")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
