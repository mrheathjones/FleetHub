//
//  AdaptiveCardStyle.swift
//  FleetHub
//


//
//  ThemeColors.swift
//  FleetHub
//
//  Adaptive color definitions for light and dark mode
//

import SwiftUI

// MARK: - Theme Colors

extension Color {
    
    // MARK: - Background Colors
    
    /// Primary background color
    static var themeBackground: Color {
        Color("ThemeBackground", bundle: nil)
    }
    
    /// Secondary/card background color
    static var themeCardBackground: Color {
        Color("ThemeCardBackground", bundle: nil)
    }
    
    // MARK: - Adaptive Colors
    
    /// Adaptive text color - primary
    static func adaptiveText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .primary
    }
    
    /// Adaptive text color - secondary
    static func adaptiveSecondaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .gray : .secondary
    }
    
    /// Adaptive card background
    static func adaptiveCardBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.8)
    }
    
    /// Adaptive card border
    static func adaptiveCardBorder(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.08)
    }
    
    /// Adaptive divider
    static func adaptiveDivider(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
    
    /// Adaptive subtle background (for hover states, etc.)
    static func adaptiveSubtleBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)
    }
    
    /// Adaptive hover background
    static func adaptiveHoverBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
}

// MARK: - FleetHub Design Tokens

/// The FleetHub palette: flat surfaces on a cool grey ground, one accent, and
/// three status pairs. Every token resolves light/dark by itself, so views do
/// not need to read `colorScheme` to use them.
enum FleetHubTheme {

    /// Window ground behind every card.
    static let ground = Color(light: 0xF3F5F9, dark: 0x0E1117)
    /// Card and bar surface.
    static let surface = Color(light: 0xFFFFFF, dark: 0x171B24)
    /// Recessed surface: segmented-control troughs, table headers.
    static let trough = Color(light: 0xE9EDF4, dark: 0x0A0D13)
    /// Hairline around cards and controls.
    static let border = Color(light: 0xE3E7EF, dark: 0x262C38)
    /// Primary text.
    static let ink = Color(light: 0x111827, dark: 0xF2F4F8)
    /// Secondary text. 4.5:1 or better on `surface` and `ground`.
    static let muted = Color(light: 0x5B6475, dark: 0xA3ACBD)
    /// Unselected control text.
    static let control = Color(light: 0x3B4558, dark: 0xC5CCDA)

    /// Built-in accent, used when the ui profile delivers none.
    static let defaultAccent = Color(light: 0x2952E3, dark: 0x7C96FF)

    /// The accent in use: the admin's `ui userInterface.accentColor` when
    /// delivered, otherwise the built-in FleetHub blue.
    static var accent: Color { Branding.configuredAccent ?? defaultAccent }

    /// Accent as a FILL behind white text (primary buttons). Darker than
    /// `accent` in dark mode, where the text accent is too light to carry
    /// white labels at 4.5:1.
    static var accentFill: Color {
        Branding.configuredAccent ?? Color(light: 0x2952E3, dark: 0x3D63F0)
    }

    static let goodText = Color(light: 0x0B6B41, dark: 0x6FD8A5)
    static let goodFill = Color(light: 0xE4F5EC, dark: 0x12301F)
    static let warnText = Color(light: 0x7A4800, dark: 0xF2C26B)
    static let warnFill = Color(light: 0xFFF1D6, dark: 0x3A2A0C)
    static let badText = Color(light: 0x9B1C15, dark: 0xFF9C94)
    static let badFill = Color(light: 0xFDE7E5, dark: 0x3D1513)

    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
}

extension Color {
    /// A color that follows the effective appearance of the view it is drawn in.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// White card on the FleetHub ground: 20pt corners, hairline border, no shadow.
struct FleetHubCardStyle: ViewModifier {
    var padding: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
    }
}

extension View {
    func fleetHubCard(padding: CGFloat = 22) -> some View {
        modifier(FleetHubCardStyle(padding: padding))
    }
}

// MARK: - Theme View Modifiers

struct AdaptiveCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12
    var hasShadow: Bool = true
    
    func body(content: Content) -> some View {
        content
            .background(Color.adaptiveCardBackground(colorScheme))
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.adaptiveCardBorder(colorScheme), lineWidth: 1)
            )
            .shadow(
                color: hasShadow && colorScheme == .light ? .black.opacity(0.05) : .clear,
                radius: 10,
                x: 0,
                y: 4
            )
    }
}

extension View {
    func adaptiveCard(cornerRadius: CGFloat = 12, hasShadow: Bool = true) -> some View {
        modifier(AdaptiveCardStyle(cornerRadius: cornerRadius, hasShadow: hasShadow))
    }
}

// MARK: - Sidebar Adaptive Colors

extension Color {
    /// Sidebar background
    static func sidebarBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.6)
    }
    
    /// Sidebar item background when selected
    static func sidebarSelectedBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.blue.opacity(0.1)
    }
    
    /// Sidebar item text when selected
    static func sidebarSelectedText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .blue
    }
    
    /// Sidebar item text when not selected
    static func sidebarText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .gray : .secondary
    }
}

// MARK: - Status Badge Colors

extension Color {
    static func statusBadgeBackground(_ baseColor: Color, _ colorScheme: ColorScheme) -> Color {
        baseColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
    }
}