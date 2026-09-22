import SwiftUI
import WidgetKit

/// One rendering surface for the real extension and the in-app previews.
struct FarmWidgetCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let card: FarmWidgetCard
    let farmName: String
    let generatedAt: Date
    var timeZoneIdentifier: String = "Asia/Shanghai"
    var medium = false
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: card.kind.symbol).widgetAccentable()
                Text(card.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 2)
                if medium { Text(farmName).foregroundStyle(secondaryInk).lineLimit(1) }
            }
            .font(.caption)
            if card.unavailable {
                Spacer(minLength: 0)
                Text(card.note).font(.caption).foregroundStyle(secondaryInk).lineLimit(4)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    metric
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if medium {
                        detailRows
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
                if let range = rangeText {
                    Text(range).font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
                } else if medium {
                    Text(card.note).font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                if stale {
                    Label("快照已过期", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(usesColorfulInk ? ink : .orange)
                } else {
                    Text("快照 \(timeText)")
                }
                Spacer(minLength: 0)
                if !medium { Text(farmName).lineLimit(1) }
            }
            .font(.system(size: 10))
            .foregroundStyle(secondaryInk)
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var metric: some View {
        if card.kind == .feeding, let progress = card.progress {
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 7)
                Circle().trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 3) {
                    Text(card.value + " " + card.unit).font(.system(size: 22, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
                    Text("已有投喂量").font(.system(size: 10)).foregroundStyle(secondaryInk)
                }.padding(10)
            }
            .frame(width: 92, height: 92)
        } else { standardMetric }
    }

    private var standardMetric: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.subtitle).font(.system(size: 11)).foregroundStyle(secondaryInk).lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.value)
                    .font(.system(size: medium ? 40 : 42, weight: card.palette == .paper ? .regular : .semibold,
                                  design: card.palette == .paper ? .serif : .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(numberInk)
                    .widgetAccentable()
                Text(card.unit).font(.system(size: 11)).foregroundStyle(secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
            }
            if !medium, card.kind == .gain, let sample = card.rows.first {
                Text("可计算 \(sample.value)").font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
            }
            if let progress = card.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.14))
                        Capsule().fill(accent)
                            .frame(width: geometry.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 4)
                .accessibilityLabel("记录覆盖比例")
                .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
            } else if !medium, card.kind == .breeding, card.palette == .coral {
                calendarStrip
            } else if !medium && card.rangeStart == nil {
                Text(card.note).font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(2)
            }
        }
    }

    private var usesColorfulInk: Bool { card.palette.isColorful && renderingMode == .fullColor }
    private var ink: Color {
        if usesColorfulInk { return card.palette.colorfulInk }
        return renderingMode == .fullColor ? (colorScheme == .dark ? .white : Color(red: 0.16, green: 0.23, blue: 0.20)) : .primary
    }
    private var secondaryInk: Color { usesColorfulInk ? card.palette.colorfulSecondary : .secondary }
    private var numberInk: Color { usesColorfulInk && card.palette == .emerald ? Color(red: 0.90, green: 1, blue: 0.68) : ink }
    private var accent: Color { usesColorfulInk ? card.palette.colorfulAccent : card.palette.color }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.rows.prefix(3)) { row in
                if card.palette == .twilight {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label).font(.system(size: 10)).foregroundStyle(secondaryInk)
                        Text(row.value).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.label).foregroundStyle(secondaryInk)
                        Spacer(minLength: 2)
                        Text(row.value).fontWeight(.medium)
                    }
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .padding(card.palette == .twilight ? 10 : 0)
        .background {
            if card.palette == .twilight {
                RoundedRectangle(cornerRadius: 12).fill(ink.opacity(0.09))
            }
        }
    }

    private var calendarStrip: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let start = calendar.startOfDay(for: generatedAt)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let dueDays = Set((card.upcomingDates ?? []).map { calendar.startOfDay(for: $0) })
        return HStack(spacing: 3) {
            ForEach(days, id: \.self) { day in
                let hasReminder = dueDays.contains(day)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 9, weight: hasReminder ? .bold : .regular))
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .foregroundStyle(hasReminder && usesColorfulInk ? Color(red: 0.48, green: 0.13, blue: 0.12) : secondaryInk)
                    .background {
                        if hasReminder {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(usesColorfulInk ? Color(red: 1, green: 0.91, blue: 0.71) : Color.primary.opacity(0.12))
                        }
                    }
                    .accessibilityLabel("\(calendar.component(.month, from: day))月\(calendar.component(.day, from: day))日，\(hasReminder ? "有预产提醒" : "无预产提醒")")
            }
        }
    }
    private var timeText: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: generatedAt)
    }
    private var rangeText: String? {
        guard let start = card.rangeStart, let end = card.rangeEnd else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: start))–\(formatter.string(from: end)) · \(card.note)"
    }
}

extension FarmWidgetPalette {
    var color: Color {
        switch self {
        case .sage: Color(red: 0.25, green: 0.47, blue: 0.34)
        case .paper: Color(red: 0.58, green: 0.47, blue: 0.30)
        case .blue: Color(red: 0.28, green: 0.46, blue: 0.68)
        case .rose: Color(red: 0.66, green: 0.37, blue: 0.49)
        case .amber: Color(red: 0.67, green: 0.47, blue: 0.20)
        case .emerald: Color(red: 0, green: 0.42, blue: 0.31)
        case .coral: Color(red: 0.75, green: 0.20, blue: 0.20)
        case .twilight: Color(red: 0.25, green: 0.28, blue: 0.64)
        case .lemon: Color(red: 0.80, green: 0.78, blue: 0.22)
        }
    }
    var gradientColors: [Color] {
        switch self {
        case .emerald: [color, Color(red: 0.04, green: 0.44, blue: 0.31), Color(red: 0.07, green: 0.45, blue: 0.30)]
        case .coral: [color, Color(red: 0.76, green: 0.23, blue: 0.20), Color(red: 0.74, green: 0.26, blue: 0.19)]
        case .twilight: [color, Color(red: 0.34, green: 0.30, blue: 0.66), Color(red: 0.54, green: 0.30, blue: 0.58)]
        case .lemon: [Color(red: 0.94, green: 0.91, blue: 0.46), Color(red: 0.96, green: 0.93, blue: 0.61), Color(red: 0.85, green: 0.91, blue: 0.53)]
        default: [color, color]
        }
    }
    var colorfulInk: Color { self == .lemon ? Color(red: 0.15, green: 0.27, blue: 0.19) : .white }
    var colorfulSecondary: Color {
        self == .lemon ? Color(red: 0.24, green: 0.34, blue: 0.20) : Color(red: 0.96, green: 0.97, blue: 0.94)
    }
    var colorfulAccent: Color {
        self == .lemon ? Color(red: 0.19, green: 0.37, blue: 0.25) : Color(red: 0.90, green: 1, blue: 0.78)
    }
}

struct FarmWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: FarmWidgetPalette
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if palette.isColorful {
                LinearGradient(colors: palette.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground)
                palette.color.opacity(colorScheme == .dark ? 0.22 : 0.11)
            }
            if palette == .sage || palette == .emerald {
                Ellipse().fill(palette == .emerald ? Color.white.opacity(0.08) : palette.color.opacity(0.08))
                    .frame(width: 220, height: 110).rotationEffect(.degrees(-18)).offset(x: 60, y: 60)
            } else if palette == .coral {
                Circle().stroke(Color.yellow.opacity(0.035), lineWidth: 24)
                    .frame(width: 140, height: 140).offset(x: 48, y: 25)
            } else if palette == .twilight {
                Ellipse().fill(Color.pink.opacity(0.12))
                    .frame(width: 180, height: 150).offset(x: 55, y: 85)
            }
        }
    }
}
