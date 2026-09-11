import SwiftUI

/// Compact visual treatment with a full-height target and native toggle state.
struct ConsentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(configuration.isOn ? AppTheme.brand : .secondary)
                    .accessibilityHidden(true)
                configuration.label
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已勾选" : "未勾选")
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
