import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .clipShape(.rect(cornerRadius: 18))
        }
    }
}

struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color
    @ViewBuilder let destination: () -> Destination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconColor: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowContent(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsActionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color
    var showsChevron = true
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconColor: Color,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.showsChevron = showsChevron
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowContent(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor,
                showsChevron: showsChevron
            )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsRowContent: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color
    var showsChevron = true

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            SettingsIcon(systemImage: systemImage, color: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30, alignment: .center)
            .background(color.gradient, in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct SettingsCardDivider: View {
    var leading: CGFloat = 57

    var body: some View {
        Divider()
            .padding(.leading, leading)
    }
}
