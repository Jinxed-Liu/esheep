import SwiftUI

enum AppTheme {
    static let brand = Color(red: 0.06, green: 0.38, blue: 0.78)
    static let brandSoft = Color(red: 0.12, green: 0.50, blue: 0.94)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
}

struct GlassCard<Content: View>: View {
    @ViewBuilder private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
