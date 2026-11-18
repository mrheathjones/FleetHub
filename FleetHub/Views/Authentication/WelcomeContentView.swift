//
//  WelcomeContentView.swift
//  FleetHub
//
//  The two-panel card every pre-dashboard screen sits in: a dark brand panel
//  on the left (mark, headline, what the app does) and the screen's own
//  content on the right. Sign-in and biometric unlock both use it.
//

import SwiftUI

struct SignInPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var width: CGFloat = 0

    /// Below this the brand panel is dropped and the content stands alone
    /// under a compact brand row.
    private var showsBrandPanel: Bool { width >= 760 }

    var body: some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()

            HStack(spacing: 0) {
                if showsBrandPanel {
                    SignInBrandPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 20) {
                    if !showsBrandPanel {
                        HStack(spacing: 10) {
                            BrandMark(size: 32)
                            Text(Branding.productName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(FleetHubTheme.ink)
                        }
                    }
                    content()
                }
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(FleetHubTheme.surface)
            }
            .frame(maxWidth: showsBrandPanel ? 960 : 480)
            .frame(height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 20, y: 12)
            .padding(24)
        }
        .readWidth(into: $width)
    }
}

/// The left half: fixed dark in both appearances, like the mock.
private struct SignInBrandPanel: View {
    @Environment(\.openURL) private var openURL

    private let ground = Color(light: 0x111827, dark: 0x0B0E14)
    private let secondary = Color(light: 0xC5CCDA, dark: 0xC5CCDA)

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                BrandMark(size: 40)
                Text(Branding.productName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Your Apple Fleet, in One Place.")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Branding.signInBlurb)
                    .font(.system(size: 15))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(icon: "magnifyingglass", title: "Search Macs, iPhones and iPads by name, serial or user")
                FeatureRow(icon: "checkmark.shield", title: "Five health checks across the whole fleet")
                FeatureRow(icon: "list.bullet.rectangle", title: "Every action is role-gated and logged")
            }

            // Only rendered when the ui domain delivers a documentationURL —
            // a link with nowhere to go is worse than no link.
            if let learnMoreURL = Branding.documentationURL {
                Button {
                    openURL(learnMoreURL)
                } label: {
                    HStack(spacing: 6) {
                        Text("Learn More")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(light: 0xAFC1FF, dark: 0xAFC1FF))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }
}

/// Inline message box used on the sign-in and unlock screens.
struct SignInNotice: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .foregroundStyle(FleetHubTheme.warnText)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.warnFill))
    }
}
