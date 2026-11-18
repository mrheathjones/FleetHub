//
//  SSOButton.swift
//  FleetHub
//
//  The full-width primary and secondary buttons on the sign-in and unlock
//  screens.
//

import SwiftUI

struct SSOButton: View {
    enum Kind { case primary, secondary }

    var icon: String?
    let title: String
    var kind: Kind = .primary
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(kind == .primary ? Color.white : FleetHubTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(kind == .primary ? FleetHubTheme.accentFill : FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(kind == .primary ? Color.clear : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
