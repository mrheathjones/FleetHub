//
//  Branding.swift
//  FleetHub
//
//  Single source of truth for admin-brandable UI values, resolved from the
//  ui managed-preference domain (schemas/FleetHub_UI_SCHEMA.json). Every
//  surface that renders the product name, wordmark, accent, logo, or
//  branded URLs must read from here — never a string literal — so an org
//  can rebrand the console entirely from the config profile.
//

import SwiftUI

enum Branding {

    private static var config: MDMConfiguration {
        MDMConfigurationManager.shared.configuration
    }

    private static var ui: UserInterfaceSettings? {
        config.userInterfaceExtras
    }

    // MARK: - Names

    /// ui userInterface.appTitle (default "FleetHub").
    static var title: String { config.appTitle }

    /// ui userInterface.appSubtitle (default "Console").
    static var subtitle: String { config.appSubtitle }

    /// Combined product name ("FleetHub").
    static var productName: String {
        subtitle.isEmpty ? title : "\(title) \(subtitle)"
    }

    /// ui userInterface.companyName, falling back to the product name.
    static var companyName: String {
        ui?.effectiveCompanyName ?? productName
    }

    /// Welcome-screen tagline (ui userInterface.tagline).
    static var tagline: String {
        ui?.effectiveTagline ?? "Device Management Made Simple"
    }

    /// The paragraph under the sign-in headline: the org's tagline when one
    /// is configured, else the built-in description of what the app is for.
    static var signInBlurb: String {
        ui?.effectiveTagline ?? "Find a device, see its health, and act on it without opening Jamf Pro."
    }

    /// About-card footer (ui userInterface.footerText); composed from the
    /// product name and current year when not configured.
    static var footerText: String {
        if let configured = ui?.effectiveFooterText { return configured }
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) \(productName). All rights reserved."
    }

    // MARK: - URLs

    /// Support link (ui userInterface.supportURL). nil = hide the affordance.
    static var supportURL: URL? {
        config.supportURL.flatMap { URL(string: $0) }
    }

    /// Documentation link (ui userInterface.documentationURL). nil = hidden.
    static var documentationURL: URL? {
        ui?.effectiveDocumentationURL.flatMap { URL(string: $0) }
    }

    /// Report-an-Issue link (ui userInterface.feedbackURL). nil = hidden.
    static var feedbackURL: URL? {
        ui?.effectiveFeedbackURL.flatMap { URL(string: $0) }
    }

    /// Custom organization logo (ui userInterface.logoURL). nil = built-in mark.
    static var logoURL: URL? {
        ui?.effectiveLogoURL.flatMap { URL(string: $0) }
    }

    // MARK: - Accent

    /// The accent the admin explicitly delivered, or nil when the profile
    /// leaves branding to the app.
    static var configuredAccent: Color? {
        guard let hex = ui?.accentColor else { return nil }
        return color(fromHex: hex)
    }

    /// Brand accent color (ui userInterface.accentColor, default the
    /// FleetHub blue — `FleetHubTheme.defaultAccent`).
    static var accentColor: Color {
        FleetHubTheme.accent
    }

    /// The two-stop brand gradient used BEHIND WHITE TEXT (primary buttons,
    /// the brand mark). Derived from `accentFill`, not `accent`: in dark mode
    /// the text accent is too light to carry white labels.
    static var accentGradient: [Color] {
        let fill = FleetHubTheme.accentFill
        return [fill, fill.opacity(0.85)]
    }

    /// Parses "#RRGGBB" / "RRGGBB" (also 8-digit #AARRGGBB, alpha ignored).
    static func color(fromHex hex: String) -> Color? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if cleaned.count == 8 { cleaned = String(cleaned.suffix(6)) }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

// MARK: - Brand Mark

/// The in-window brand mark: the org's custom logo (ui userInterface.logoURL)
/// when delivered, otherwise the built-in FleetHub monogram tile.
struct BrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        if let url = Branding.logoURL {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                builtInMark
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        } else {
            builtInMark
        }
    }

    private var builtInMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2227, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(light: 0x272B35, dark: 0x272B35), Color(light: 0x0C0E12, dark: 0x0C0E12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            MonogramGlyph()
            RoundedRectangle(cornerRadius: size * 0.2227, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: max(0.5, size / 256))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The built-in FleetHub mark: an "F" made of three glass bars that brighten
/// where they overlap. Same geometry as the app icon (see
/// docs/design/render-app-icon.swift), authored on a 512pt grid.
struct MonogramGlyph: View {
    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 512
            let bars: [(CGRect, UInt32, UInt32)] = [
                (CGRect(x: 132, y: 100, width: 252, height: 88), 0x5FF0D6, 0x0FA3B8),  // top, teal
                (CGRect(x: 132, y: 212, width: 180, height: 88), 0xC99BFF, 0x7A3DF0),  // middle, violet
                (CGRect(x: 132, y: 100, width: 88, height: 312), 0x6FA8FF, 0x2456F5)   // stem, blue
            ]
            // Own layer, so the bars screen-blend with each other and not
            // with whatever is behind the mark.
            context.drawLayer { layer in
                layer.blendMode = .screen
                for (rect, start, end) in bars {
                    let scaled = CGRect(
                        x: rect.minX * scale, y: rect.minY * scale,
                        width: rect.width * scale, height: rect.height * scale
                    )
                    let path = Path(roundedRect: scaled, cornerRadius: 44 * scale)
                    layer.fill(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(light: start, dark: start).opacity(0.9),
                                Color(light: end, dark: end).opacity(0.9)
                            ]),
                            startPoint: CGPoint(x: scaled.minX, y: scaled.minY),
                            endPoint: CGPoint(x: scaled.maxX, y: scaled.maxY)
                        )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
