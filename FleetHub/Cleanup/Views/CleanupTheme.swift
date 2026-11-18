//
//  CleanupTheme.swift
//  FleetHub
//
//  Visual language for the Cleanup feature, on the FleetHub tokens: flat
//  surface cards on the grey ground, a circular back button, a stale badge, a tri-state checkbox, and shared date formatters.
//

import SwiftUI

/// Card styling for Cleanup: the flat FleetHub surface with a hairline border.
/// (The name predates the redesign; it is no longer translucent.)
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
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
    func glassCard() -> some View { modifier(GlassCard()) }
}

/// FleetHub-style circular back button (matches DeviceView / MobileDeviceView).
struct CleanupBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .fill(FleetHubTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to Cleanup")
    }
}

/// Color-coded "days stale" badge.
struct StaleBadge: View {
    let days: Int?

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isSevere ? FleetHubTheme.badFill : FleetHubTheme.warnFill, in: Capsule())
            .foregroundStyle(isSevere ? FleetHubTheme.badText : FleetHubTheme.warnText)
    }

    private var label: String {
        guard let days else { return "Never" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// 90 days or more, or never seen at all.
    private var isSevere: Bool {
        days.map { $0 >= 90 } ?? true
    }
}

/// Tri-state checkbox used by the cleanup device lists.
struct CleanupCheckBox: View {
    enum State { case off, on, mixed }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Deselect" : "Select")
    }

    private var symbol: String {
        switch state {
        case .off: "square"
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        }
    }
}

enum CleanupFormatters {
    static let lastContact: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func lastContactString(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return lastContact.string(from: date)
    }

    /// Stable, locale-independent timestamp for report cells.
    static let report: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func reportDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return report.string(from: date)
    }

    /// Date stamp for export filenames, e.g. 2026-06-11.
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func fileDate(_ date: Date) -> String {
        fileStamp.string(from: date)
    }
}
