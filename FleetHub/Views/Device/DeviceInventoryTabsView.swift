//
//  DeviceInventoryTabsView.swift
//  FleetHub
//
//  The searchable, paginated inventory sections of the computer detail view
//  (applications, profiles, local accounts, certificates, printers, groups,
//  extension attributes). Each list's search/page state is a
//  PaginatedListState held by DeviceInventoryState, which the detail view
//  owns so search, filters, and page survive switching sections.
//

import SwiftUI
import Observation

// MARK: - State

@Observable
final class DeviceInventoryState {
    enum CertificateFilter: String, CaseIterable {
        case all = "All"
        case valid = "Valid"
        case expiring = "Expiring"
        case expired = "Expired"
    }

    let applications = PaginatedListState<Application> { app, text in
        (app.name ?? "").localizedCaseInsensitiveContains(text) ||
        (app.bundleId ?? "").localizedCaseInsensitiveContains(text)
    }

    let profiles = PaginatedListState<ConfigurationProfile> { profile, text in
        (profile.displayName ?? "").localizedCaseInsensitiveContains(text) ||
        (profile.profileIdentifier ?? "").localizedCaseInsensitiveContains(text)
    }

    let localAccounts = PaginatedListState<LocalUserAccount> { account, text in
        (account.fullName ?? "").localizedCaseInsensitiveContains(text) ||
        (account.username ?? "").localizedCaseInsensitiveContains(text)
    }

    let certificates = PaginatedListState<Certificate> { cert, text in
        (cert.commonName ?? "").localizedCaseInsensitiveContains(text) ||
        (cert.subjectName ?? "").localizedCaseInsensitiveContains(text)
    }

    let printers = PaginatedListState<Printer> { printer, text in
        (printer.name ?? "").localizedCaseInsensitiveContains(text) ||
        (printer.location ?? "").localizedCaseInsensitiveContains(text) ||
        (printer.type ?? "").localizedCaseInsensitiveContains(text)
    }

    let groups = PaginatedListState<GroupMembership> { group, text in
        (group.groupName ?? "").localizedCaseInsensitiveContains(text)
    }

    let extensionAttributes = PaginatedListState<ExtensionAttribute> { attr, text in
        (attr.name ?? "").localizedCaseInsensitiveContains(text) ||
        (attr.values?.joined(separator: " ") ?? "").localizedCaseInsensitiveContains(text)
    }

    // Local Accounts tag filters. Each chip is a tag: an account shows only if
    // one of its tags is selected, so no selection means no accounts. System
    // accounts start deselected to keep service users out of the way.
    var filterAdminAccounts: Bool = true {
        didSet { if filterAdminAccounts != oldValue { localAccounts.resetPage() } }
    }
    var filterStandardAccounts: Bool = true {
        didSet { if filterStandardAccounts != oldValue { localAccounts.resetPage() } }
    }
    var filterFileVaultAccounts: Bool = true {
        didSet { if filterFileVaultAccounts != oldValue { localAccounts.resetPage() } }
    }
    var filterSystemAccounts: Bool = false {
        didSet { if filterSystemAccounts != oldValue { localAccounts.resetPage() } }
    }

    // Groups filters
    var filterSmartGroups: Bool = true {
        didSet { if filterSmartGroups != oldValue { groups.resetPage() } }
    }
    var filterStaticGroups: Bool = true {
        didSet { if filterStaticGroups != oldValue { groups.resetPage() } }
    }

    // Certificates filter
    var certificateFilter: CertificateFilter = .all {
        didSet { if certificateFilter != oldValue { certificates.resetPage() } }
    }

    /// False when every tag chip is deselected — nothing can match, and the
    /// empty state says so rather than pretending a filter excluded everything.
    var hasSelectedAccountTags: Bool {
        filterAdminAccounts || filterStandardAccounts
            || filterFileVaultAccounts || filterSystemAccounts
    }
}

// MARK: - Inventory table building blocks

// One surface card per inventory section: toolbar (title, count, search),
// optional filter chips, a ground-coloured column header, hairline rows and
// a pager footer. Shared by the computer, mobile, history and log sections.

struct InventoryCardShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FleetHubTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }
}

struct InventoryToolbar<Accessory: View>: View {
    let title: String
    /// e.g. "42" or "8 of 42"; nil hides it.
    var countText: String?
    var search: Binding<String>?
    var searchPrompt = "Search"
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                if let countText {
                    Text(countText)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(FleetHubTheme.muted)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            accessory()

            if let search {
                InventorySearchField(text: search, prompt: searchPrompt)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

extension InventoryToolbar where Accessory == EmptyView {
    init(title: String, countText: String? = nil, search: Binding<String>? = nil, searchPrompt: String = "Search") {
        self.init(title: title, countText: countText, search: search, searchPrompt: searchPrompt) { EmptyView() }
    }
}

struct InventorySearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.ink)
            if !text.isEmpty {
                Button {
                    text = ""
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
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }
}

/// Wrapping row of filter chips under the toolbar.
struct InventoryFilterRow<Chips: View>: View {
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        FlowLayout(spacing: 6) {
            chips()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

struct InventoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.control)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? FleetHubTheme.accent.opacity(0.12) : FleetHubTheme.surface))
                .overlay(Capsule().stroke(isSelected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Ground-coloured column-title strip.
struct InventoryHeaderRow<Columns: View>: View {
    @ViewBuilder let columns: () -> Columns

    var body: some View {
        columns()
            .padding(.horizontal, 20)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetHubTheme.ground)
    }
}

struct InventoryHeaderText: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FleetHubTheme.muted)
            .lineLimit(1)
    }
}

/// One table row with the hairline under it.
struct InventoryRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
        }
    }
}

/// Three-column layout shared by a section's header and its rows: a flexible
/// leading column and two fixed ones.
struct InventoryColumns<A: View, B: View, C: View>: View {
    let widths: (CGFloat, CGFloat)
    @ViewBuilder let first: () -> A
    @ViewBuilder let second: () -> B
    @ViewBuilder let third: () -> C

    var body: some View {
        HStack(spacing: 14) {
            first().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            second().frame(width: widths.0, alignment: .leading)
            third().frame(width: widths.1, alignment: .trailing)
        }
    }
}

/// Name over a muted second line — the leading cell of most rows.
struct InventoryPrimaryCell<Tags: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var tags: () -> Tags

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                tags()
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

extension InventoryPrimaryCell where Tags == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct InventoryCellText: View {
    let text: String

    init(_ text: String?) { self.text = text ?? "" }

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 13))
            .foregroundStyle(text.isEmpty ? FleetHubTheme.muted : FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Small pill in the four status tones.
struct InventoryTag: View {
    enum Tone { case good, warn, bad, neutral, accent }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
    }

    private var ink: Color {
        switch tone {
        case .good: FleetHubTheme.goodText
        case .warn: FleetHubTheme.warnText
        case .bad: FleetHubTheme.badText
        case .neutral: FleetHubTheme.control
        case .accent: FleetHubTheme.accent
        }
    }

    private var fill: Color {
        switch tone {
        case .good: FleetHubTheme.goodFill
        case .warn: FleetHubTheme.warnFill
        case .bad: FleetHubTheme.badFill
        case .neutral: FleetHubTheme.trough
        case .accent: FleetHubTheme.accent.opacity(0.12)
        }
    }
}

/// Footer strip: "Showing 1–25 of 80" and previous / next.
struct InventoryPager: View {
    @Binding var page: Int
    let totalPages: Int
    let totalItems: Int
    /// 0-based index of the first row shown.
    let startIndex: Int
    /// 0-based index one past the last row shown.
    let endIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("Showing \(totalItems == 0 ? 0 : startIndex + 1)–\(endIndex) of \(totalItems)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
            Spacer(minLength: 8)
            Text("Page \(page) of \(totalPages)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
                .padding(.trailing, 6)
            button("chevron.left", label: "Previous Page", enabled: page > 1) {
                page = max(1, page - 1)
            }
            button("chevron.right", label: "Next Page", enabled: page < totalPages) {
                page = min(totalPages, page + 1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(FleetHubTheme.ground)
    }

    private func button(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
                .frame(width: 40, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FleetHubTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The current page of rows, then the pager when there is more than a page.
struct InventoryPagedRows<Row: Identifiable, RowContent: View>: View {
    @Bindable var state: PaginatedListState<Row>
    let rows: [Row]
    @ViewBuilder let rowContent: (Row) -> RowContent

    var body: some View {
        let slice = state.slice(of: rows)

        LazyVStack(spacing: 0) {
            ForEach(slice.rows) { row in
                InventoryRow { rowContent(row) }
            }
        }

        if slice.needsPagination {
            InventoryPager(
                page: $state.page,
                totalPages: slice.totalPages,
                totalItems: slice.totalItems,
                startIndex: slice.startIndex,
                endIndex: slice.endIndex
            )
        }
    }
}

/// Centred message inside a card: nothing recorded, or nothing matches.
struct InventoryEmptyState: View {
    let icon: String
    let title: String
    var message: String?
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .multilineTextAlignment(.center)
            }
            if let buttonTitle, let action {
                Button(action: action) {
                    CleanupOutlineLabel(text: buttonTitle)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 20)
    }
}

/// "42", or "8 of 42" when a search or filter narrows the list.
func inventoryCountText(shown: Int, total: Int) -> String {
    shown == total ? "\(total)" : "\(shown) of \(total)"
}

// MARK: - View

struct DeviceInventoryTabsView: View {
    let section: DeviceSection
    let computer: Computer
    @Bindable var state: DeviceInventoryState

    // One sort per table; a column key is the column's own title.
    @State private var applicationSort = TableSort<String>()
    @State private var profileSort = TableSort<String>()
    @State private var accountSort = TableSort<String>()
    @State private var certificateSort = TableSort<String>()
    @State private var printerSort = TableSort<String>()
    @State private var groupSort = TableSort<String>()
    @State private var attributeSort = TableSort<String>()

    var body: some View {
        switch section {
        case .applications:
            applicationsSection
        case .profiles:
            profilesSection
        case .localAccounts:
            localAccountsSection
        case .certificates:
            certificatesSection
        case .printers:
            printersSection
        case .groupMemberships:
            groupMembershipsSection
        case .extensionAttributes:
            extensionAttributesSection
        default:
            EmptyView()
        }
    }

    // MARK: - Applications Section

    private var applicationsSection: some View {
        let apps = computer.applications ?? []
        let filtered = state.applications.filter(apps).sorted(by: applicationSort) { app, column in
            switch column {
            case "Version": .text(app.version ?? app.cfBundleShortVersionString)
            case "Size": .number(app.sizeMegabytes.map { Double($0) })
            default: .text(app.name)
            }
        }

        return InventoryCardShell {
            if apps.isEmpty {
                InventoryToolbar(title: "Applications", countText: "0")
                InventoryEmptyState(icon: "app.badge", title: "No Applications Found")
            } else {
                InventoryToolbar(
                    title: "Applications",
                    countText: inventoryCountText(shown: filtered.count, total: apps.count),
                    search: Bindable(state.applications).searchText,
                    searchPrompt: "Name or bundle ID"
                )
                InventoryHeaderRow {
                    InventoryColumns(widths: (150, 90)) {
                        SortableHeaderText("Application", key: "Application", sort: $applicationSort)
                    } second: {
                        SortableHeaderText("Version", key: "Version", sort: $applicationSort)
                    } third: {
                        SortableHeaderText("Size", key: "Size", sort: $applicationSort)
                    }
                }
                if filtered.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Applications Match")
                } else {
                    InventoryPagedRows(state: state.applications, rows: filtered) { app in
                        applicationRow(app)
                    }
                }
            }
        }
    }

    private func applicationRow(_ app: Application) -> some View {
        InventoryColumns(widths: (150, 90)) {
            InventoryPrimaryCell(title: app.name ?? "Unknown", subtitle: app.bundleId) {
                if app.updateAvailable == true {
                    InventoryTag(text: "Update Available", tone: .warn)
                }
                if app.macAppStore == true {
                    InventoryTag(text: "App Store", tone: .accent)
                }
            }
        } second: {
            InventoryCellText(app.version ?? app.cfBundleShortVersionString)
        } third: {
            InventoryCellText(app.sizeMegabytes.map { DeviceFormatting.storage($0) })
        }
    }

    // MARK: - Configuration Profiles Section

    private var profilesSection: some View {
        let profiles = computer.configurationProfiles ?? []
        let filtered = state.profiles.filter(profiles).sorted(by: profileSort) { profile, column in
            switch column {
            case "Installed": .isoDate(profile.lastInstalled)
            case "Removable": .flag(profile.removable ?? false)
            default: .text(profile.displayName)
            }
        }

        return InventoryCardShell {
            if profiles.isEmpty {
                InventoryToolbar(title: "Configuration Profiles", countText: "0")
                InventoryEmptyState(icon: "doc.badge.gearshape", title: "No Configuration Profiles")
            } else {
                InventoryToolbar(
                    title: "Configuration Profiles",
                    countText: inventoryCountText(shown: filtered.count, total: profiles.count),
                    search: Bindable(state.profiles).searchText,
                    searchPrompt: "Name or identifier"
                )
                InventoryHeaderRow {
                    InventoryColumns(widths: (170, 100)) {
                        SortableHeaderText("Profile", key: "Profile", sort: $profileSort)
                    } second: {
                        SortableHeaderText("Installed", key: "Installed", sort: $profileSort)
                    } third: {
                        SortableHeaderText("Removable", key: "Removable", sort: $profileSort)
                    }
                }
                if filtered.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Profiles Match")
                } else {
                    InventoryPagedRows(state: state.profiles, rows: filtered) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: ConfigurationProfile) -> some View {
        InventoryColumns(widths: (170, 100)) {
            InventoryPrimaryCell(title: profile.displayName ?? "Unknown Profile", subtitle: profile.profileIdentifier)
        } second: {
            InventoryCellText(profile.lastInstalled.flatMap { DeviceFormatting.date($0) })
        } third: {
            if profile.removable == true {
                InventoryTag(text: "Removable", tone: .good)
            } else {
                InventoryCellText(nil)
            }
        }
    }

    // MARK: - Local Accounts Section

    private var localAccountsSection: some View {
        let accounts = computer.localUserAccounts ?? []
        let filteredAccounts = filteredLocalAccounts(from: accounts).sorted(by: accountSort) { account, column in
            switch column {
            case "UID": .text(account.uid)
            case "Home Size": .number(account.homeDirectorySizeMb.flatMap { $0 > 0 ? Double($0) : nil })
            default: .text(account.fullName ?? account.username)
            }
        }

        return InventoryCardShell {
            if accounts.isEmpty {
                InventoryToolbar(title: "Local User Accounts", countText: "0")
                InventoryEmptyState(icon: "person.2", title: "No Local User Accounts")
            } else {
                InventoryToolbar(
                    title: "Local User Accounts",
                    countText: inventoryCountText(shown: filteredAccounts.count, total: accounts.count),
                    search: Bindable(state.localAccounts).searchText,
                    searchPrompt: "Name or username"
                )
                InventoryFilterRow {
                    InventoryChip(title: "Admin", isSelected: state.filterAdminAccounts) {
                        state.filterAdminAccounts.toggle()
                    }
                    InventoryChip(title: "Standard", isSelected: state.filterStandardAccounts) {
                        state.filterStandardAccounts.toggle()
                    }
                    InventoryChip(title: "FileVault", isSelected: state.filterFileVaultAccounts) {
                        state.filterFileVaultAccounts.toggle()
                    }
                    InventoryChip(title: "System", isSelected: state.filterSystemAccounts) {
                        state.filterSystemAccounts.toggle()
                    }
                }
                InventoryHeaderRow {
                    InventoryColumns(widths: (90, 100)) {
                        SortableHeaderText("Account", key: "Account", sort: $accountSort)
                    } second: {
                        SortableHeaderText("UID", key: "UID", sort: $accountSort)
                    } third: {
                        SortableHeaderText("Home Size", key: "Home Size", sort: $accountSort)
                    }
                }

                if filteredAccounts.isEmpty {
                    InventoryEmptyState(
                        icon: "line.3.horizontal.decrease.circle",
                        title: state.hasSelectedAccountTags ? "No Accounts Match Filters" : "No Filtered Users",
                        message: state.hasSelectedAccountTags ? nil : "Select a tag above to show accounts.",
                        buttonTitle: "Select All Tags"
                    ) {
                        state.filterAdminAccounts = true
                        state.filterStandardAccounts = true
                        state.filterFileVaultAccounts = true
                        state.filterSystemAccounts = true
                    }
                } else {
                    InventoryPagedRows(state: state.localAccounts, rows: filteredAccounts) { account in
                        localAccountRow(account)
                    }
                }
            }
        }
    }

    private func filteredLocalAccounts(from accounts: [LocalUserAccount]) -> [LocalUserAccount] {
        // Every chip is a tag, and an account shows only while one of its own
        // tags is selected. Deselecting a chip always hides those accounts —
        // there is no "nothing selected means everything" escape hatch.
        state.localAccounts.filter(accounts) { account in
            let matchesType: Bool
            switch account.accountType {
            case .admin: matchesType = state.filterAdminAccounts
            case .standard: matchesType = state.filterStandardAccounts
            case .system: matchesType = state.filterSystemAccounts
            }

            return matchesType
                || (state.filterFileVaultAccounts && account.fileVault2Enabled == true)
        }
    }

    /// Label + tone for an account's type, matching its tag chip.
    private func accountTypeStyle(_ type: LocalUserAccount.AccountType) -> (label: String, tone: InventoryTag.Tone) {
        switch type {
        case .admin:    return ("Admin", .warn)
        case .standard: return ("Standard", .accent)
        case .system:   return ("System", .neutral)
        }
    }

    private func localAccountRow(_ account: LocalUserAccount) -> some View {
        let type = accountTypeStyle(account.accountType)
        let subtitle = [account.username, account.homeDirectory]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return InventoryColumns(widths: (90, 100)) {
            InventoryPrimaryCell(title: account.fullName ?? account.username ?? "Unknown", subtitle: subtitle) {
                InventoryTag(text: type.label, tone: type.tone)
                if account.fileVault2Enabled == true {
                    InventoryTag(text: "FileVault", tone: .good)
                }
            }
        } second: {
            InventoryCellText(account.uid ?? "N/A")
        } third: {
            InventoryCellText(account.homeDirectorySizeMb.flatMap { $0 > 0 ? DeviceFormatting.storage($0) : nil })
        }
    }

    // MARK: - Certificates Section

    private var certificatesSection: some View {
        let certs = computer.certificates ?? []
        let filteredCerts = filteredCertificates(from: certs).sorted(by: certificateSort) { cert, column in
            switch column {
            case "Expires": .isoDate(cert.expirationDate)
            case "Status": .text(certificateStatusInfo(cert).label)
            default: .text(cert.commonName)
            }
        }

        return InventoryCardShell {
            if certs.isEmpty {
                InventoryToolbar(title: "Certificates", countText: "0")
                InventoryEmptyState(icon: "checkmark.seal", title: "No Certificates Found")
            } else {
                InventoryToolbar(
                    title: "Certificates",
                    countText: inventoryCountText(shown: filteredCerts.count, total: certs.count),
                    search: Bindable(state.certificates).searchText,
                    searchPrompt: "Common name or subject"
                )
                InventoryFilterRow {
                    ForEach(DeviceInventoryState.CertificateFilter.allCases, id: \.self) { filter in
                        InventoryChip(title: filter.rawValue, isSelected: state.certificateFilter == filter) {
                            state.certificateFilter = filter
                        }
                    }
                }
                InventoryHeaderRow {
                    InventoryColumns(widths: (170, 90)) {
                        SortableHeaderText("Certificate", key: "Certificate", sort: $certificateSort)
                    } second: {
                        SortableHeaderText("Expires", key: "Expires", sort: $certificateSort)
                    } third: {
                        SortableHeaderText("Status", key: "Status", sort: $certificateSort)
                    }
                }

                if filteredCerts.isEmpty {
                    InventoryEmptyState(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No Certificates Match Filters",
                        buttonTitle: "Show All"
                    ) {
                        state.certificateFilter = .all
                        state.certificates.searchText = ""
                    }
                } else {
                    InventoryPagedRows(state: state.certificates, rows: filteredCerts) { cert in
                        certificateRow(cert)
                    }
                }
            }
        }
    }

    private func filteredCertificates(from certs: [Certificate]) -> [Certificate] {
        // Apply search filter
        var result = state.certificates.filter(certs)

        // Apply status filter
        switch state.certificateFilter {
        case .all:
            break
        case .valid:
            result = result.filter { $0.certificateStatus == "ISSUED" || $0.lifecycleStatus == "ACTIVE" }
        case .expiring:
            result = result.filter { cert in
                guard let expiryString = cert.expirationDate,
                      let expiryDate = ISO8601DateFormatter().date(from: expiryString) else {
                    return false
                }
                let thirtyDaysFromNow = Date().addingTimeInterval(30 * 24 * 60 * 60)
                return expiryDate > Date() && expiryDate <= thirtyDaysFromNow
            }
        case .expired:
            result = result.filter { cert in
                if cert.certificateStatus == "EXPIRED" {
                    return true
                }
                guard let expiryString = cert.expirationDate,
                      let expiryDate = ISO8601DateFormatter().date(from: expiryString) else {
                    return false
                }
                return expiryDate < Date()
            }
        }

        return result
    }

    private func certificateRow(_ cert: Certificate) -> some View {
        let status = certificateStatusInfo(cert)

        return InventoryColumns(widths: (170, 90)) {
            InventoryPrimaryCell(title: cert.commonName ?? "Unknown Certificate", subtitle: cert.subjectName)
        } second: {
            InventoryCellText(cert.expirationDate.map { DeviceFormatting.date($0) ?? $0 })
        } third: {
            InventoryTag(text: status.label, tone: status.tone)
        }
    }

    private func certificateStatusInfo(_ cert: Certificate) -> (label: String, tone: InventoryTag.Tone) {
        // Check if expired first
        if cert.certificateStatus?.uppercased() == "EXPIRED" {
            return ("Expired", .bad)
        }

        // Check expiration date
        if let expiryString = cert.expirationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var expiryDate = formatter.date(from: expiryString)
            if expiryDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiryDate = formatter.date(from: expiryString)
            }

            if let expiry = expiryDate {
                // Check if expired
                if expiry < Date() {
                    return ("Expired", .bad)
                }

                // Check if expiring within 30 days
                let thirtyDaysFromNow = Date().addingTimeInterval(30 * 24 * 60 * 60)
                if expiry <= thirtyDaysFromNow {
                    return ("Expiring", .warn)
                }
            }
        }

        // Valid certificate
        return ("Valid", .good)
    }

    // MARK: - Printers Section

    private var printersSection: some View {
        let printers = computer.printers ?? []
        let filteredPrinters = state.printers.filter(printers).sorted(by: printerSort) { printer, column in
            switch column {
            case "Type": .text(printer.type)
            case "Location": .text(printer.location)
            default: .text(printer.name)
            }
        }

        return InventoryCardShell {
            if printers.isEmpty {
                InventoryToolbar(title: "Printers", countText: "0")
                InventoryEmptyState(icon: "printer", title: "No Printers Configured")
            } else {
                InventoryToolbar(
                    title: "Printers",
                    countText: inventoryCountText(shown: filteredPrinters.count, total: printers.count),
                    search: Bindable(state.printers).searchText,
                    searchPrompt: "Name, location, or type"
                )
                InventoryHeaderRow {
                    InventoryColumns(widths: (170, 170)) {
                        SortableHeaderText("Printer", key: "Printer", sort: $printerSort)
                    } second: {
                        SortableHeaderText("Type", key: "Type", sort: $printerSort)
                    } third: {
                        SortableHeaderText("Location", key: "Location", sort: $printerSort)
                    }
                }
                if filteredPrinters.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Printers Match Search")
                } else {
                    InventoryPagedRows(state: state.printers, rows: filteredPrinters) { printer in
                        printerRow(printer)
                    }
                }
            }
        }
    }

    private func printerRow(_ printer: Printer) -> some View {
        InventoryColumns(widths: (170, 170)) {
            InventoryPrimaryCell(title: printer.name ?? "Unknown Printer", subtitle: printer.uri)
        } second: {
            InventoryCellText(printer.type)
        } third: {
            InventoryCellText(printer.location)
        }
    }

    // MARK: - Group Memberships Section

    private var groupMembershipsSection: some View {
        let groups = computer.groupMemberships ?? []
        let filteredGroupsList = filteredGroups(from: groups).sorted(by: groupSort) { group, column in
            switch column {
            case "ID": .text(group.groupId)
            case "Type": .text(group.smartGroup == true ? "Smart Group" : "Static Group")
            default: .text(group.groupName)
            }
        }

        return InventoryCardShell {
            if groups.isEmpty {
                InventoryToolbar(title: "Group Memberships", countText: "0")
                InventoryEmptyState(icon: "person.3", title: "No Group Memberships")
            } else {
                InventoryToolbar(
                    title: "Group Memberships",
                    countText: inventoryCountText(shown: filteredGroupsList.count, total: groups.count),
                    search: Bindable(state.groups).searchText,
                    searchPrompt: "Group name"
                )
                InventoryFilterRow {
                    InventoryChip(title: "Smart Groups", isSelected: state.filterSmartGroups) {
                        state.filterSmartGroups.toggle()
                    }
                    InventoryChip(title: "Static Groups", isSelected: state.filterStaticGroups) {
                        state.filterStaticGroups.toggle()
                    }
                }
                InventoryHeaderRow {
                    InventoryColumns(widths: (90, 110)) {
                        SortableHeaderText("Group", key: "Group", sort: $groupSort)
                    } second: {
                        SortableHeaderText("ID", key: "ID", sort: $groupSort)
                    } third: {
                        SortableHeaderText("Type", key: "Type", sort: $groupSort)
                    }
                }

                if filteredGroupsList.isEmpty {
                    InventoryEmptyState(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No Groups Match Filters",
                        buttonTitle: "Show All"
                    ) {
                        state.filterSmartGroups = true
                        state.filterStaticGroups = true
                        state.groups.searchText = ""
                    }
                } else {
                    InventoryPagedRows(state: state.groups, rows: filteredGroupsList) { group in
                        groupRow(group)
                    }
                }
            }
        }
    }

    private func filteredGroups(from groups: [GroupMembership]) -> [GroupMembership] {
        // Apply search filter
        var result = state.groups.filter(groups)

        // Apply type filters
        if !state.filterSmartGroups || !state.filterStaticGroups {
            result = result.filter { group in
                let isSmart = group.smartGroup == true
                if state.filterSmartGroups && isSmart { return true }
                if state.filterStaticGroups && !isSmart { return true }
                return false
            }
        }

        return result
    }

    private func groupRow(_ group: GroupMembership) -> some View {
        InventoryColumns(widths: (90, 110)) {
            InventoryPrimaryCell(title: group.groupName ?? "Unknown Group")
        } second: {
            InventoryCellText(group.groupId ?? "N/A")
        } third: {
            InventoryTag(
                text: group.smartGroup == true ? "Smart Group" : "Static Group",
                tone: group.smartGroup == true ? .accent : .neutral
            )
        }
    }

    // MARK: - Extension Attributes Section

    private var extensionAttributesSection: some View {
        let attrs = computer.extensionAttributes ?? []
        let filteredAttrs = state.extensionAttributes.filter(attrs).sorted(by: attributeSort) { attr, column in
            switch column {
            case "Value": .text(attr.values?.joined(separator: ", "))
            case "Type": .text(attr.dataType)
            default: .text(attr.name)
            }
        }

        return InventoryCardShell {
            if attrs.isEmpty {
                InventoryToolbar(title: "Extension Attributes", countText: "0")
                InventoryEmptyState(icon: "list.bullet.rectangle", title: "No Extension Attributes")
            } else {
                InventoryToolbar(
                    title: "Extension Attributes",
                    countText: inventoryCountText(shown: filteredAttrs.count, total: attrs.count),
                    search: Bindable(state.extensionAttributes).searchText,
                    searchPrompt: "Name or value"
                )
                InventoryHeaderRow {
                    extensionAttributeColumns {
                        SortableHeaderText("Attribute", key: "Attribute", sort: $attributeSort)
                    } value: {
                        SortableHeaderText("Value", key: "Value", sort: $attributeSort)
                    } type: {
                        SortableHeaderText("Type", key: "Type", sort: $attributeSort)
                    }
                }
                if filteredAttrs.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Attributes Match Search")
                } else {
                    InventoryPagedRows(state: state.extensionAttributes, rows: filteredAttrs) { attr in
                        extensionAttributeRow(attr)
                    }
                }
            }
        }
    }

    /// Name and value share the width evenly — values are often long.
    private func extensionAttributeColumns<A: View, B: View, C: View>(
        @ViewBuilder name: () -> A,
        @ViewBuilder value: () -> B,
        @ViewBuilder type: () -> C
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            name().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            value().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            type().frame(width: 90, alignment: .trailing)
        }
    }

    private func extensionAttributeRow(_ attr: ExtensionAttribute) -> some View {
        extensionAttributeColumns {
            InventoryPrimaryCell(
                title: attr.name ?? "Unknown Attribute",
                subtitle: attr.definitionId.map { "ID: \($0)" }
            )
        } value: {
            if let values = attr.values, !values.isEmpty {
                Text(values.joined(separator: ", "))
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                InventoryCellText(nil)
            }
        } type: {
            if let dataType = attr.dataType {
                InventoryTag(text: dataType)
            }
        }
    }
}
