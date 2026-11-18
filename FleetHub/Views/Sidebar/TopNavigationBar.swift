//
//  TopNavigationBar.swift
//  FleetHub
//
//  The FleetHub window bar: brand mark, module pills, and the announcements,
//  preferences and account controls. Replaces the left sidebar.
//
//  WHAT appears here is still decided by SidebarView's static resolvers (the
//  user's role `modules` intersected with this Mac's kill switches) — this
//  file only changes how those entries are drawn.
//

import SwiftUI

struct TopNavigationBar: View {
    @Binding var selectedDestination: NavigationDestination
    @Binding var isInNestedView: Bool
    let onNavigate: (NavigationDestination) -> Void
    let onLogout: () -> Void

    /// Observed so the pills re-resolve when capabilities land after sign-in
    /// or a profile push changes the machine layer mid-session.
    @ObservedObject private var session = UserSession.shared
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @ObservedObject private var announcements = AnnouncementService.shared

    @State private var showAccount = false

    /// Room for the window's traffic lights, which sit over the bar because
    /// the window uses a hidden title bar.
    private let trafficLightInset: CGFloat = 84

    private var entries: [SidebarView.ResolvedSidebarEntry] {
        SidebarView.resolvedEntries(
            config: configManager.configuration,
            capabilities: session.capabilities
        )
    }

    /// Announcements is drawn as the megaphone button, not as a pill.
    private var pillEntries: [SidebarView.ResolvedSidebarEntry] {
        entries.filter { $0.destination != .announcements }
    }

    private var announcementsEntry: SidebarView.ResolvedSidebarEntry? {
        entries.first { $0.destination == .announcements }
    }

    private var showsSettings: Bool {
        SidebarView.showsSettings(
            config: configManager.configuration,
            capabilities: session.capabilities
        )
    }

    private func isSelected(_ destination: NavigationDestination) -> Bool {
        selectedDestination == destination && !isInNestedView
    }

    var body: some View {
        HStack(spacing: 16) {
            brand
            Spacer(minLength: 0)
            // Widest arrangement first; when the labelled pills cannot fit,
            // fall back to icon-only pills rather than truncating labels.
            ViewThatFits(in: .horizontal) {
                pills(showLabels: true)
                pills(showLabels: false)
            }
            Spacer(minLength: 0)
            trailingControls
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 20)
        .frame(height: 56)
        .background(FleetHubTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    // MARK: - Brand

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 28)
            Text(Branding.productName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Module pills

    private func pills(showLabels: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(pillEntries) { entry in
                NavigationPill(
                    title: entry.title,
                    icon: entry.icon,
                    showLabel: showLabels,
                    isSelected: isSelected(entry.destination)
                ) {
                    onNavigate(entry.destination)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FleetHubTheme.ground)
        )
    }

    // MARK: - Trailing controls

    private var trailingControls: some View {
        HStack(spacing: 8) {
            if let entry = announcementsEntry {
                BarIconButton(
                    icon: entry.icon,
                    label: unreadCount > 0 ? "\(entry.title), \(unreadCount) unread" : entry.title,
                    isSelected: isSelected(.announcements),
                    badge: unreadCount
                ) {
                    onNavigate(.announcements)
                }
            }

            if showsSettings {
                BarIconButton(
                    icon: "slider.horizontal.3",
                    label: "Settings",
                    isSelected: isSelected(.settings),
                    badge: 0
                ) {
                    onNavigate(.settings)
                }
            }

            accountButton
        }
    }

    private var unreadCount: Int {
        announcements.showUnreadBadge ? announcements.unreadCount : 0
    }

    /// Log Out lives here and is never gated: it must stay reachable for a
    /// user whose roles grant no module at all.
    private var accountButton: some View {
        Button {
            showAccount.toggle()
        } label: {
            HStack(spacing: 8) {
                ProfileAvatarView(size: 26)
                    .frame(width: 26, height: 26)
                if !session.displayName.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.ink)
                            .lineLimit(1)
                            .fixedSize()
                        // First role only; the popover lists them all.
                        if let role = session.roles.first {
                            Text(role)
                                .font(.system(size: 11))
                                .foregroundStyle(FleetHubTheme.muted)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, session.displayName.isEmpty ? 5 : 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .popover(isPresented: $showAccount, arrowEdge: .bottom) {
            accountPopover
        }
    }

    private var accountPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !session.displayName.isEmpty {
                    Text(session.displayName)
                        .font(.system(size: 14, weight: .semibold))
                }
                if !session.email.isEmpty {
                    Text(session.email)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !session.roles.isEmpty {
                    Text(session.roles.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button(role: .destructive) {
                showAccount = false
                onLogout()
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FleetHubTheme.badText)
        }
        .padding(16)
        .frame(minWidth: 220, alignment: .leading)
    }
}

// MARK: - Navigation Pill

private struct NavigationPill: View {
    let title: String
    let icon: String
    let showLabel: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !showLabel {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                }
                if showLabel {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.control)
            .padding(.horizontal, showLabel ? 14 : 11)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(showLabel ? "" : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return FleetHubTheme.surface }
        return isHovered ? FleetHubTheme.surface.opacity(0.6) : .clear
    }
}

// MARK: - Bar Icon Button

private struct BarIconButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.control)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .fill(isSelected ? FleetHubTheme.accent.opacity(0.12) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .stroke(isSelected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(Color(light: 0xB3261E, dark: 0xC8362D)))
                            .offset(x: 6, y: -6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Top Navigation Bar") {
    @Previewable @State var selected: NavigationDestination = .dashboard
    @Previewable @State var isNested: Bool = false
    VStack(spacing: 0) {
        TopNavigationBar(
            selectedDestination: $selected,
            isInNestedView: $isNested,
            onNavigate: { selected = $0 },
            onLogout: {}
        )
        FleetHubTheme.ground
    }
    .frame(width: 1200, height: 300)
}
#endif
