//
//  SettingsView.swift
//  FleetHub
//
//  Settings: a section list on the left and one card per section on the
//  right — Profile, Preferences, Unlock, Credentials, About and Reset.
//

import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Observed so the Cleanup-only controls re-evaluate when capabilities
    /// land after sign-in.
    @ObservedObject private var session = UserSession.shared

    @ObservedObject private var menuBar = MenuBarCompanion.shared
    @State private var showingResetAlert = false
    @State private var biometricTestResult: String?
    @State private var biometricTestOK = false
    @State private var showsAvatarOptions = false
    @State private var selectedSection: Section = .profile
    @State private var pageWidth: CGFloat = 0

    /// The stale threshold is shared with Cleanup and the Devices list.
    /// 0 = unset → the MDM profile's default.
    @AppStorage(CleanupSettings.Key.staleDays) private var staleDaysStored = 0

    private enum Section: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case preferences = "Preferences"
        case unlock = "Unlock"
        case credentials = "Credentials"
        case about = "About"
        case reset = "Reset"

        var id: String { rawValue }
    }

    private var effectiveStaleDays: Int {
        staleDaysStored > 0 ? staleDaysStored : MDMConfigurationManager.shared.configuration.cleanupStaleDays
    }

    private var staleDayOptions: [Int] {
        Array(Set([7, 14, 30, 45, 60, 90, 120, 180, 365, effectiveStaleDays]))
            .filter { $0 > 0 }
            .sorted()
    }

    private var canUseCleanup: Bool {
        session.capabilities.canAccess(module: NavigationDestination.cleanup.rawValue)
    }

    private var showsSectionList: Bool { pageWidth >= 820 }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 32) {
                if showsSectionList {
                    sectionList(proxy)
                        .frame(width: 200)
                        .padding(.top, 24)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !showsSectionList {
                            Text("Settings")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(FleetHubTheme.ink)
                        }
                        profileCard.id(Section.profile)
                        preferencesCard.id(Section.preferences)
                        unlockCard.id(Section.unlock)
                        credentialsCard.id(Section.credentials)
                        aboutCard.id(Section.about)
                        resetCard.id(Section.reset)
                    }
                    .padding(.vertical, 24)
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .readWidth(into: $pageWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground.ignoresSafeArea())
        .alert("Reset Settings", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                withAnimation { settings.resetToDefaults() }
            }
        } message: {
            Text("This will reset all settings to their default values. This action cannot be undone.")
        }
    }

    // MARK: - Section list

    private func sectionList(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .padding(.bottom, 12)

            ForEach(Section.allCases) { section in
                let isSelected = selectedSection == section
                Button {
                    selectedSection = section
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(section, anchor: .top)
                    }
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(isSelected ? FleetHubTheme.border : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: - Profile

    private var signInMethod: MDMConfiguration.SignInMethod {
        MDMConfigurationManager.shared.configuration.signInMethod
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    identity
                    Spacer(minLength: 12)
                    profileButtons
                }
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    profileButtons
                }
            }

            if showsAvatarOptions {
                Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
                avatarPicker
            }
        }
        .fleetHubCard(padding: 22)
    }

    private var identity: some View {
        HStack(spacing: 18) {
            ProfileAvatarView(size: 72)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(FleetHubTheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName.isEmpty ? "Signed-In User" : session.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)

                if !session.email.isEmpty {
                    Text(session.email)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                FlowLayout(spacing: 6) {
                    if session.roles.isEmpty {
                        SettingsTag(text: "No Role Assigned", tone: .warn)
                            .help("Contact your admin about \(Branding.productName) role assignment.")
                    } else {
                        ForEach(session.roles, id: \.self) { role in
                            SettingsTag(text: "Role: \(role)", tone: .accent)
                        }
                    }
                    SettingsTag(text: signInMethod == .entra ? "Microsoft Entra ID" : "Email Sign-In")
                }
                .padding(.top, 4)
            }
        }
    }

    private var profileButtons: some View {
        HStack(spacing: 8) {
            Button {
                chooseProfilePicture()
            } label: {
                SettingsButtonLabel(text: "Choose Photo…")
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsAvatarOptions.toggle() }
            } label: {
                SettingsButtonLabel(
                    text: "Customize Avatar",
                    icon: showsAvatarOptions ? "chevron.up" : "chevron.down"
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Avatar picker

    /// Tile edge for the avatar option cells.
    private let avatarTile: CGFloat = 46

    private var liveInitials: String {
        ProfileAvatarView.initials(displayName: session.displayName, email: session.email)
    }

    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupLabel("Avatar")

            FlowLayout(spacing: 10) {
                // Custom photo — tapping (re)opens the file picker
                avatarOptionTile(selected: settings.avatarStyle == .photo, label: "Custom Photo") {
                    chooseProfilePicture()
                } content: {
                    if let photo = settings.customProfilePicture {
                        AvatarBadge(size: avatarTile, image: photo, symbol: nil, initials: "", colorIndex: 0)
                    } else {
                        photoPlaceholderTile
                    }
                }

                // Microsoft directory photo (only when one was fetched)
                if let entra = session.profilePhoto {
                    avatarOptionTile(selected: settings.avatarStyle == .auto, label: "Directory Photo") {
                        settings.avatarStyle = .auto
                    } content: {
                        AvatarBadge(size: avatarTile, image: entra, symbol: nil, initials: "", colorIndex: 0)
                    }
                }

                // Initials avatar (in the chosen color)
                avatarOptionTile(selected: settings.avatarStyle == .initials, label: "Initials") {
                    settings.avatarStyle = .initials
                } content: {
                    AvatarBadge(size: avatarTile, image: nil, symbol: nil, initials: liveInitials, colorIndex: settings.avatarColorIndex)
                }

                // Symbol avatars (in the chosen color)
                ForEach(AvatarPalette.symbols, id: \.self) { symbol in
                    avatarOptionTile(
                        selected: settings.avatarStyle == .symbol && settings.avatarSymbol == symbol,
                        label: "Symbol"
                    ) {
                        settings.avatarSymbol = symbol
                        settings.avatarStyle = .symbol
                    } content: {
                        AvatarBadge(size: avatarTile, image: nil, symbol: symbol, initials: "", colorIndex: settings.avatarColorIndex)
                    }
                }
            }

            // Color swatches — apply to the initials and symbol avatars
            groupLabel("Color")
            HStack(spacing: 10) {
                ForEach(Array(AvatarPalette.gradients.indices), id: \.self) { index in
                    Button {
                        settings.avatarColorIndex = index
                        // Picking a color implies a generated avatar; if the
                        // user is currently on a photo, switch to initials so
                        // the color choice is actually visible.
                        if settings.avatarStyle == .auto || settings.avatarStyle == .photo {
                            settings.avatarStyle = .initials
                        }
                    } label: {
                        Circle()
                            .fill(AvatarPalette.gradient(index))
                            .frame(width: 26, height: 26)
                            .padding(3)
                            .overlay(
                                Circle().stroke(
                                    settings.avatarColorIndex == index ? FleetHubTheme.accent : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Avatar color \(index + 1)")
                    .accessibilityAddTraits(settings.avatarColorIndex == index ? .isSelected : [])
                }
            }

            HStack(spacing: 10) {
                Text(profilePictureCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)

                if settings.customProfilePicture != nil {
                    Spacer(minLength: 8)
                    Button {
                        withAnimation {
                            settings.customProfilePicture = nil
                            if settings.avatarStyle == .photo { settings.avatarStyle = .auto }
                        }
                    } label: {
                        SettingsButtonLabel(text: "Remove Photo", kind: .destructive)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One selectable avatar cell: the badge, a selection ring, and hit target.
    private func avatarOptionTile<Content: View>(
        selected: Bool,
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .padding(3)
                .overlay(
                    Circle().stroke(selected ? FleetHubTheme.accent : Color.clear, lineWidth: 2.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var photoPlaceholderTile: some View {
        ZStack {
            Circle()
                .fill(FleetHubTheme.trough)
                .frame(width: avatarTile, height: avatarTile)
            Image(systemName: "photo.badge.plus")
                .font(.system(size: avatarTile * 0.4))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(width: avatarTile, height: avatarTile)
    }

    private var profilePictureCaption: String {
        switch settings.avatarStyle {
        case .photo:
            return settings.customProfilePicture != nil
                ? "Using a custom photo stored on this Mac."
                : "No custom photo chosen yet — pick one with Choose Photo…"
        case .auto:
            return session.profilePhoto != nil
                ? "Using your Microsoft directory photo."
                : "Using your initials."
        case .initials:
            return "Using an initials avatar."
        case .symbol:
            return "Using a symbol avatar."
        }
    }

    private func chooseProfilePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a profile picture"
        panel.prompt = "Use Photo"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        settings.customProfilePicture = image
        settings.avatarStyle = .photo
    }

    // MARK: - Preferences

    private var preferencesCard: some View {
        rowsCard(title: "Preferences") {
            settingRow("Appearance", "Follow your Mac's appearance, or always use light or dark.") {
                appearancePicker
            }
            settingRow("Auto Refresh", "Automatically refresh Overview data.") {
                menu(
                    selection: $settings.autoRefreshInterval,
                    options: [0, 60, 300, 900, 1800],
                    title: { $0 == 0 ? "Off" : "\($0 / 60) min" }
                )
            }
            settingRow("Items Per Page", "Default number of items shown in device lists.") {
                menu(
                    selection: $settings.defaultItemsPerPage,
                    options: [10, 25, 50, 100],
                    title: { "\($0)" }
                )
            }
            settingRow("Stale After", "Devices with no Jamf Pro check-in for this many days count as stale.") {
                menu(
                    selection: Binding(get: { effectiveStaleDays }, set: { staleDaysStored = $0 }),
                    options: staleDayOptions,
                    title: { "\($0) Days" }
                )
            }
            settingRow("Show Device Icons", "Show model artwork for Macs in lists and device pages.") {
                Toggle("", isOn: $settings.showDeviceIcons)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Show Device Icons")
            }
            if menuBar.isOffered {
                settingRow("Menu Bar Search", menuBarSubtitle) {
                    HStack(spacing: 10) {
                        if menuBar.needsApproval {
                            Button("Open Login Items") { menuBar.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(
                            get: { menuBar.isEnabled || menuBar.needsApproval },
                            set: { menuBar.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Menu Bar Search")
                    }
                }
                .onAppear { menuBar.refresh() }
            }
        }
    }

    private var menuBarSubtitle: String {
        if let error = menuBar.errorMessage { return error }
        if menuBar.needsApproval {
            return "Waiting for your approval in System Settings, under General, Login Items."
        }
        return "Keep a device search in the menu bar. It starts when you log in to this Mac."
    }

    private var appearancePicker: some View {
        HStack(spacing: 4) {
            ForEach(AppearanceMode.allCases) { mode in
                let isSelected = settings.appearanceMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.appearanceMode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(mode.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FleetHubTheme.trough))
        .fixedSize()
    }

    private func menu(selection: Binding<Int>, options: [Int], title: @escaping (Int) -> String) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(title(selection.wrappedValue))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.ink)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            .padding(.horizontal, 12)
            .frame(width: 140, height: 36)
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
    }

    // MARK: - Unlock

    private var unlockCard: some View {
        rowsCard(title: "Unlock") {
            settingRow(
                settings.biometricsAvailable ? "Unlock with \(settings.biometricTypeName)" : "Biometric Unlock",
                settings.biometricsAvailable
                    ? "Biometric data is stored securely on your device and never leaves it."
                    : "No biometric authentication is available on this Mac."
            ) {
                if settings.biometricsAvailable {
                    HStack(spacing: 12) {
                        if settings.biometricsEnabled {
                            Button {
                                testBiometrics()
                            } label: {
                                SettingsButtonLabel(text: "Test \(settings.biometricTypeName)")
                            }
                            .buttonStyle(.plain)
                        }
                        Toggle("", isOn: $settings.biometricsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("Unlock with \(settings.biometricTypeName)")
                    }
                } else {
                    SettingsTag(text: "Unavailable")
                }
            }

            if let result = biometricTestResult {
                Label(result, systemImage: biometricTestOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(biometricTestOK ? FleetHubTheme.goodText : FleetHubTheme.badText)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private func testBiometrics() {
        settings.authenticateWithBiometrics(reason: "Test biometric authentication") { success, error in
            withAnimation {
                biometricTestOK = success
                if success {
                    biometricTestResult = "\(settings.biometricTypeName) is working correctly."
                } else if let error {
                    biometricTestResult = "Failed: \(error.localizedDescription)"
                } else {
                    biometricTestResult = "Authentication was cancelled."
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { biometricTestResult = nil }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                cardTitle("Credentials")
                Text("Secrets are kept in this Mac's Keychain. They are never read from a configuration profile, written to preferences, or logged.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CredentialsSettingsSection(showsProtectControls: canUseCleanup)
        }
        .fleetHubCard(padding: 22)
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                BrandMark(size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Branding.productName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text(appVersionString)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)
            }

            // Links — each only renders when the ui domain delivers its
            // destination URL (dead buttons help no one).
            let links = aboutLinks
            if !links.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(links, id: \.title) { link in
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            SettingsButtonLabel(text: link.title, icon: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Copyright (ui domain footerText, or composed default)
            Text(Branding.footerText)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .fleetHubCard(padding: 22)
    }

    private var aboutLinks: [(title: String, url: URL)] {
        var links: [(title: String, url: URL)] = []
        if let url = Branding.documentationURL { links.append(("Documentation", url)) }
        if let url = Branding.supportURL { links.append(("Help & Support", url)) }
        if let url = Branding.feedbackURL { links.append(("Report an Issue", url)) }
        return links
    }

    /// Real product version from the bundle — never a hard-coded string.
    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (Build \(build))"
    }

    // MARK: - Reset

    private var resetCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reset to Defaults")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Restores preferences on this Mac. Credentials in the Keychain are kept.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                showingResetAlert = true
            } label: {
                SettingsButtonLabel(text: "Reset", kind: .destructive)
            }
            .buttonStyle(.plain)
        }
        .fleetHubCard(padding: 22)
    }

    // MARK: - Helpers

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(FleetHubTheme.ink)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FleetHubTheme.control)
    }

    /// A card of setting rows: title, then one hairline-separated row each.
    private func rowsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle(title)
                .padding(.top, 20)
                .padding(.bottom, 8)
            content()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    private func settingRow<Control: View>(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Preview

#Preview("Settings - Dark") {
    SettingsView()
        .frame(width: 1100, height: 800)
        .preferredColorScheme(.dark)
}

#Preview("Settings - Light") {
    SettingsView()
        .frame(width: 1100, height: 800)
        .preferredColorScheme(.light)
}
