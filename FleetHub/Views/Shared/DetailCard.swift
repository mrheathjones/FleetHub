//
//  DetailCard.swift
//  FleetHub
//
//  Titled glass card that stacks detail rows (or any content) with 12pt spacing.
//

import SwiftUI

struct DetailCard<Content: View>: View {
    let title: String
    /// SF Symbol shown before the title. Optional so cards that never had an
    /// icon keep a plain title.
    let icon: String?
    @ViewBuilder let content: () -> Content

    init(title: String, icon: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    /// Set by a row of cards that should share one height.
    @Environment(\.detailCardsFillHeight) private var fillsHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FleetHubTheme.muted)
                }

                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
            }
            .padding(.bottom, 4)

            // Rows bring their own vertical padding and a hairline beneath;
            // the mask trims the last row's line so the card ends clean.
            VStack(spacing: 0) {
                content()
            }
            .mask(Rectangle().padding(.bottom, 1))
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .fleetHubCard()
    }
}

// MARK: - Equal-height rows

private struct DetailCardsFillHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var detailCardsFillHeight: Bool {
        get { self[DetailCardsFillHeightKey.self] }
        set { self[DetailCardsFillHeightKey.self] = newValue }
    }
}

extension View {
    /// Makes every `DetailCard` inside stretch to the height it is offered —
    /// pair with `.fixedSize(horizontal: false, vertical: true)` on the row
    /// so the cards match the tallest one.
    func detailCardsFillHeight(_ fills: Bool = true) -> some View {
        environment(\.detailCardsFillHeight, fills)
    }
}
