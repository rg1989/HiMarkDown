import SwiftUI

/// Brand colors shared with the HTML welcome hero (indigo / accent pink).
enum HiAppearance {
    static let brand = Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)
    static let brandSecondary = Color(red: 236 / 255, green: 72 / 255, blue: 153 / 255)

    @ViewBuilder
    static func sidebarBackground() -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [brand.opacity(0.16), brand.opacity(0.06), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            Rectangle()
                .fill(brand.opacity(0.35))
                .frame(width: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    static func toolbarAccentLine() -> some View {
        LinearGradient(
            colors: [brand.opacity(0.55), brandSecondary.opacity(0.32), Color.clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
