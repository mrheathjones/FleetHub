//
//  SetupBrandingPreview.swift
//  FleetHubSetup
//
//  A picture of FleetHub's sign-in screen drawn with the branding entered
//  on the Configure step: app title, accent color, appearance, sign-in
//  method and support link. Nothing here signs in; the controls are inert.
//

import SwiftUI

struct SetupBrandingPreview: View {
    @EnvironmentObject private var model: SetupModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        let trimmed = model.appTitle.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "FleetHub" : trimmed
    }

    /// The entered hex color, or nil when it is empty or not a hex color.
    private var customAccent: Color? {
        var hex = model.accentColorHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(light: value, dark: value)
    }

    private var accent: Color { customAccent ?? SetupTheme.accentFill }

    private var scheme: ColorScheme? {
        switch model.defaultColorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign-In Preview").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                    Text(note).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                }
                Spacer()
                SetupButton(title: "Done", kind: .primary) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(SetupTheme.surface)
            Divider().overlay(SetupTheme.border)

            signInCard
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SetupTheme.ground)
                .environment(\.colorScheme, scheme ?? .light)
                .preferredColorScheme(scheme)
        }
        .frame(width: 980, height: 660)
    }

    private var note: String {
        let hex = model.accentColorHex.trimmingCharacters(in: .whitespaces)
        if !hex.isEmpty, customAccent == nil { return "“\(hex)” is not a six-digit hex color, so FleetHub blue is shown." }
        return "How FleetHub's sign-in screen looks with these settings. The buttons here do nothing."
    }

    private var signInCard: some View {
        HStack(spacing: 0) {
            // Brand panel: fixed dark in both appearances, as in FleetHub.
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    mark(size: 40)
                    Text(verbatim: title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your Apple Fleet, in One Place.")
                        .font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Find a device, see its health, and act on it without opening Jamf Pro.")
                        .font(.system(size: 15)).foregroundStyle(Color(light: 0xC5CCDA, dark: 0xC5CCDA))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 14) {
                    feature("magnifyingglass", "Search Macs, iPhones and iPads by name, serial or user")
                    feature("checkmark.shield", "Five health checks across the whole fleet")
                    feature("list.bullet.rectangle", "Every action is role-gated and logged")
                }
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(light: 0x111827, dark: 0x0B0E14))

            // Sign-in panel.
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign In").font(.system(size: 28, weight: .bold)).foregroundStyle(SetupTheme.ink)
                    Text(model.signInMethod == "entra"
                         ? "Use your organization account to continue."
                         : "Enter your work email address to continue.")
                        .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                }
                if model.signInMethod == "entra" {
                    primaryButton("Sign In with Microsoft", icon: "person.badge.key.fill")
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Email Address").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                        Text(verbatim: "first.last@example.com")
                            .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SetupTheme.fieldBorder))
                    }
                    primaryButton("Continue", icon: nil)
                }
                if model.requireBiometric {
                    HStack(spacing: 10) {
                        Image(systemName: "touchid").font(.system(size: 18)).foregroundStyle(accent)
                        Text("After your first sign-in you can unlock \(title) with Touch ID.")
                            .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    if !model.supportURL.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(spacing: 6) {
                            Text("Need help?").foregroundStyle(SetupTheme.muted)
                            Text("Contact Support").fontWeight(.semibold).foregroundStyle(accent)
                        }
                        .font(.system(size: 13))
                    }
                    let company = model.companyName.trimmingCharacters(in: .whitespaces)
                    if !company.isEmpty {
                        Text(verbatim: company).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    }
                }
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SetupTheme.surface)
        }
        .frame(maxWidth: 900)
        .frame(height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(SetupTheme.border))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 12)
    }

    /// FleetHub's own icon, as the app shows it when the profile delivers
    /// no custom logo. Setup's app icon carries a gear badge, so the plain
    /// FleetHub artwork is bundled separately for this preview.
    private func mark(size: CGFloat) -> some View {
        Image("FleetHubIconArt")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(text).font(.system(size: 13)).foregroundStyle(Color(light: 0xC5CCDA, dark: 0xC5CCDA))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ text: String, icon: String?) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
            Text(text).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
