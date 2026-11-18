//
//  FeatureRow.swift
//  FleetHub
//
//  One "what the app does" line on the dark brand panel of the sign-in card.
//

import SwiftUI

struct FeatureRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(light: 0xAFC1FF, dark: 0xAFC1FF))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(light: 0x1F2A40, dark: 0x1F2A40))
                )

            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
