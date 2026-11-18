//
//  AnnouncementsView.swift
//  FleetHub
//
//  View for displaying announcements pushed via MDM configuration profiles
//  Pure SwiftUI (uses Environment openURL instead of NSWorkspace)
//

import SwiftUI

struct AnnouncementsView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var announcementService = AnnouncementService.shared
    
    @State private var selectedAnnouncement: Announcement?
    @State private var filter: AnnouncementFilter = .all
    @State private var showingAddSheet = false
    @State private var searchText = ""
    
    @FocusState private var isSearchFocused: Bool

    private var filteredAnnouncements: [Announcement] {
        var results = announcementService.activeAnnouncements
        
        switch filter {
        case .all:
            break
        case .unread:
            results = results.filter { !announcementService.isRead($0) }
        case .critical:
            results = results.filter { $0.type == .critical || $0.priority == .urgent }
        case .type(let type):
            results = results.filter { $0.type == type }
        }
        
        if !searchText.isEmpty {
            results = results.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.message.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return results
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection

            if let error = announcementService.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(error)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(FleetHubTheme.warnText)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.warnFill))
            }

            if announcementService.isLoading && announcementService.announcements.isEmpty {
                loadingView
            } else if announcementService.activeAnnouncements.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground.ignoresSafeArea())
        .sheet(item: $selectedAnnouncement) { announcement in
            AnnouncementDetailSheet(announcement: announcement, openURL: openURL)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock
                Spacer(minLength: 16)
                headerControls
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                headerControls
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Announcements")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)

            HStack(spacing: 6) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 11))
                Text(subtitle)
                    .font(.system(size: 13))
            }
            .foregroundStyle(FleetHubTheme.muted)
        }
    }

    private var subtitle: String {
        var text = "Source: \(announcementService.activeSource.rawValue)"
        if let lastRefresh = announcementService.lastRefresh {
            text += " · Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            if announcementService.unreadCount > 0 {
                Button {
                    announcementService.markAllAsRead()
                } label: {
                    SettingsButtonLabel(text: "Mark All Read", icon: "checkmark.circle")
                }
                .buttonStyle(.plain)
            }

            RefreshButton(isLoading: announcementService.isLoading) {
                announcementService.refresh()
            }

            // Local file / debug menu
            Menu {
                Section("Local Announcements File") {
                    if announcementService.localFileExists {
                        Button {
                            announcementService.openLocalDirectory()
                        } label: {
                            Label("Open in Finder", systemImage: "folder")
                        }

                        Button {
                            openURL(announcementService.localFileURL)
                        } label: {
                            Label("Edit announcements.json", systemImage: "pencil")
                        }
                    } else {
                        Button {
                            announcementService.createLocalAnnouncementsFile()
                        } label: {
                            Label("Create Local File", systemImage: "doc.badge.plus")
                        }
                    }

                    Text("Path: \(AnnouncementService.localAnnouncementsFilePath)")
                        .font(.caption)
                }

                #if DEBUG
                // Testing helpers never ship to production builds.
                Divider()

                Section("Testing") {
                    Button {
                        announcementService.addSampleAnnouncements()
                    } label: {
                        Label("Add Sample Announcements", systemImage: "plus.circle")
                    }

                    Button {
                        announcementService.clearLocalAnnouncements()
                    } label: {
                        Label("Clear Test Announcements", systemImage: "trash")
                    }
                }
                #endif
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FleetHubTheme.control)
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
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Local Announcements File")
            .accessibilityLabel("More Options")
        }
        .fixedSize()
    }

    private var sourceIcon: String {
        switch announcementService.activeSource {
        case .mdm: return "lock.shield"
        case .localFile: return "doc.text"
        case .userDefaults: return "testtube.2"
        case .none: return "questionmark.circle"
        }
    }

    private func filterPill(_ title: String, filter: AnnouncementFilter, badge: Int = 0) -> some View {
        let isSelected = self.filter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.filter = filter
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : FleetHubTheme.muted)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : FleetHubTheme.control)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(isSelected ? FleetHubTheme.accentFill : FleetHubTheme.surface))
            .overlay(Capsule().stroke(isSelected ? Color.clear : FleetHubTheme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Content

    private var contentView: some View {
        let shown = filteredAnnouncements
        let total = announcementService.activeAnnouncements.count

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FleetHubTheme.muted)
                        TextField("", text: $searchText, prompt: Text("Search announcements")
                            .foregroundColor(FleetHubTheme.muted))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.ink)
                            .focused($isSearchFocused)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(FleetHubTheme.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(minWidth: 180, maxWidth: 380)
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
                    )

                    Spacer(minLength: 8)

                    Text("\(shown.count) of \(total) Shown")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize()
                }

                FlowLayout(spacing: 6) {
                    filterPill("All", filter: .all)
                    filterPill("Unread", filter: .unread, badge: announcementService.showUnreadBadge ? announcementService.unreadCount : 0)
                    filterPill("Critical", filter: .critical)
                    ForEach(AnnouncementType.allCases) { type in
                        filterPill(type.displayName, filter: .type(type))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(FleetHubTheme.muted)
                    Text("No Matching Announcements")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text("Try adjusting your search or filters.")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { announcement in
                            AnnouncementCard(
                                announcement: announcement,
                                isRead: announcementService.isRead(announcement),
                                onTap: {
                                    announcementService.markAsRead(announcement)
                                    selectedAnnouncement = announcement
                                },
                                onDismiss: (announcement.dismissible && announcementService.allowUserDismiss) ? {
                                    withAnimation {
                                        announcementService.dismiss(announcement)
                                    }
                                } : nil
                            )
                            Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(FleetHubTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "megaphone")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)

            Text("No Announcements")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)

            Text("Announcements can be loaded from an MDM configuration profile or a local JSON file.")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if announcementService.localFileExists {
                    Button {
                        announcementService.openLocalDirectory()
                    } label: {
                        SettingsButtonLabel(text: "Open Folder", icon: "folder")
                    }
                    .buttonStyle(.plain)

                    Button {
                        openURL(announcementService.localFileURL)
                    } label: {
                        SettingsButtonLabel(text: "Edit File", kind: .primary, icon: "pencil")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        announcementService.createLocalAnnouncementsFile()
                    } label: {
                        SettingsButtonLabel(text: "Create Local Announcements File", kind: .primary, icon: "doc.badge.plus")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)

            Text(verbatim: "File path: \(AnnouncementService.localAnnouncementsFilePath)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FleetHubTheme.muted)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)

            #if DEBUG
            // Testing helper never ships to production builds.
            Button {
                announcementService.addSampleAnnouncements()
            } label: {
                SettingsButtonLabel(text: "Add Sample Announcements for Testing", icon: "testtube.2")
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .fleetHubCard()
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Announcements…")
                .font(.system(size: 14))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Announcement Filter

enum AnnouncementFilter: Equatable {
    case all
    case unread
    case critical
    case type(AnnouncementType)
}

// MARK: - Tone

/// Text and fill tokens for an announcement type, replacing the system
/// rainbow so tiles and tags pass contrast in both appearances.
private func announcementTone(_ type: AnnouncementType) -> (ink: Color, fill: Color) {
    switch type {
    case .info, .update: return (FleetHubTheme.accent, FleetHubTheme.accent.opacity(0.12))
    case .warning: return (FleetHubTheme.warnText, FleetHubTheme.warnFill)
    case .critical: return (FleetHubTheme.badText, FleetHubTheme.badFill)
    case .success: return (FleetHubTheme.goodText, FleetHubTheme.goodFill)
    case .maintenance: return (FleetHubTheme.control, FleetHubTheme.trough)
    }
}

private func priorityTag(_ priority: AnnouncementPriority) -> some View {
    SettingsTag(text: priority.rawValue.capitalized, tone: priority == .urgent ? .bad : .warn)
}

// MARK: - Announcement Card

/// One row of the announcements table card.
struct AnnouncementCard: View {
    let announcement: Announcement
    let isRead: Bool
    let onTap: () -> Void
    let onDismiss: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        let tone = announcementTone(announcement.type)

        HStack(spacing: 14) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Image(systemName: announcement.type.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tone.ink)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tone.fill))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if !isRead {
                                Circle()
                                    .fill(FleetHubTheme.accent)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("Unread")
                            }

                            Text(announcement.title)
                                .font(.system(size: 14, weight: isRead ? .semibold : .bold))
                                .foregroundStyle(FleetHubTheme.ink)
                                .lineLimit(1)

                            if announcement.priority == .urgent || announcement.priority == .high {
                                priorityTag(announcement.priority)
                            }

                            if announcement.requiredReading && !isRead {
                                SettingsTag(text: "Required", tone: .bad)
                            }

                            Spacer(minLength: 8)

                            Text(announcement.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 12))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize()
                        }

                        Text(AnnouncementMarkdownView.inlineAttributed(announcement.message))
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if announcement.actionURL != nil {
                            HStack(spacing: 4) {
                                Text(announcement.actionLabel ?? "Learn More")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDismiss = onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss \(announcement.title)")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Announcement Detail Sheet

struct AnnouncementDetailSheet: View {
    let announcement: Announcement
    let openURL: OpenURLAction

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tone = announcementTone(announcement.type)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: announcement.type.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tone.ink)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.fill))

                VStack(alignment: .leading, spacing: 6) {
                    Text(announcement.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        Text(announcement.type.displayName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tone.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.fill))

                        if announcement.priority == .urgent || announcement.priority == .high {
                            priorityTag(announcement.priority)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.control)
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AnnouncementMarkdownView(text: announcement.message)
                        .font(.system(size: 14))
                        .foregroundColor(FleetHubTheme.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    VStack(spacing: 0) {
                        metadataRow(label: "Posted", value: announcement.createdAt.formatted(date: .long, time: .shortened))

                        if let expiresAt = announcement.expiresAt {
                            metadataRow(label: "Expires", value: expiresAt.formatted(date: .long, time: .shortened))
                        }

                        metadataRow(label: "Priority", value: announcement.priority.rawValue.capitalized)

                        if announcement.requiredReading {
                            metadataRow(label: "Required Reading", value: "Yes")
                        }
                    }

                    if let urlString = announcement.actionURL, let url = URL(string: urlString) {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: 8) {
                                Text(announcement.actionLabel ?? "Learn More")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(FleetHubTheme.accentFill)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 520, height: 480)
        .background(FleetHubTheme.surface)
    }

    private func metadataRow(label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 16) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.ink)
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Announcements View") {
    AnnouncementsView()
        .frame(width: 1200, height: 800)
        .onAppear {
            AnnouncementService.shared.addSampleAnnouncements()
        }
}
#endif
