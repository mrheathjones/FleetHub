//
//  SSHTerminalWindow.swift
//  FleetHub
//
//  The FleetHub window an SSH session runs in: a header naming the device,
//  the account and how long the session has been open, a notice about when
//  the management account's password rotates, and the terminal itself.
//
//  The terminal is SwiftTerm's local-process view running /usr/bin/ssh over
//  the connection SSHSession already signed in.
//

import SwiftUI
import AppKit
import Observation
import SwiftTerm

struct SSHSessionInfo {
    let deviceName: String
    let serialNumber: String
    let deviceID: String
    let username: String
    let host: String
    let viaVPN: Bool
    let startedAt: Date
    /// When Jamf is due to rotate the password that signed this session in.
    let rotatesAt: Date?
    /// True when `rotatesAt` is worked out from the configured rotation
    /// period rather than read from Jamf.
    let rotationIsEstimate: Bool
    /// Which kind of session the window belongs to; only the wording differs.
    var kind: Kind = .ssh
    /// Why `rotatesAt` is an estimate, in a sentence, when it is one.
    var rotationNote: String? = nil

    /// Extra facts shown as rows in a companion panel.
    var details: [Detail] = []

    enum Kind { case ssh, screenShare, localAdminPassword, fileVaultKey }

    struct Detail {
        let label: String
        let value: String
        /// true = good, false = needs attention, nil = neutral.
        let isGood: Bool?
    }
}

/// A password read from Jamf, with the time Jamf is due to rotate it.
struct FetchedPassword {
    let username: String
    let password: String
    let rotatesAt: Date?
    let rotationIsEstimate: Bool
    let rotationNote: String?
}

/// Works out when a LAPS password rotates. Jamf rotates a password a set
/// time after it is FIRST viewed, so a password someone looked at half an
/// hour ago has half an hour less left than one viewed just now. The audit
/// history records each view and the password's expiry.
enum LAPSRotation {
    struct Result: Equatable {
        let rotatesAt: Date?
        let isEstimate: Bool
        let note: String?
    }

    /// - Parameters:
    ///   - auditJSON: body of `.../account/{username}/audit`, when it was read.
    ///   - auditStatus: HTTP status of that call; nil when it never answered.
    ///   - password: the password just fetched; the audit entry holding the
    ///     same password is the current one.
    ///   - fetchedAt: when this app read the password (itself a view).
    ///   - jamfPeriod: `passwordRotationTime` from Jamf's LAPS settings, when
    ///     the role can read them.
    ///   - configuredPeriod: the profile's rotation period, used otherwise.
    static func resolve(auditJSON: Data?, auditStatus: Int?, password: String, fetchedAt: Date,
                        jamfPeriod: TimeInterval?, configuredPeriod: TimeInterval) -> Result {
        let period = jamfPeriod ?? configuredPeriod
        let fallback = fetchedAt.addingTimeInterval(period)

        guard let auditJSON, auditStatus == 200 else {
            let note = auditStatus == 403
                ? "Estimated from now. The Jamf API role needs View Local Admin Password Audit History to show the real time."
                : "Estimated from now. Jamf's password audit history could not be read."
            return Result(rotatesAt: fallback, isEstimate: true, note: note)
        }

        struct Audit: Decodable {
            struct View: Decodable { let dateSeen: String? }
            struct Entry: Decodable {
                let password: String?
                let expirationTime: String?
                let audits: [View]?
            }
            let results: [Entry]
        }
        guard let audit = try? JSONDecoder().decode(Audit.self, from: auditJSON),
              let entry = audit.results.first(where: { $0.password == password }) else {
            return Result(rotatesAt: fallback, isEstimate: true,
                          note: "Estimated from now. Jamf's audit history does not list this password yet.")
        }

        let expiration = entry.expirationTime.flatMap(date)
        let firstView = (entry.audits ?? []).compactMap { $0.dateSeen.flatMap(date) }.min()

        // The clock starts at the first view Jamf recorded; when Jamf has not
        // recorded one yet, this app's own read is the first.
        let viewBased = (firstView ?? fetchedAt).addingTimeInterval(period)
        // An expiry far beyond the view-based time is the unviewed
        // auto-rotation date, which a view replaces.
        if let expiration, firstView != nil || expiration <= viewBased.addingTimeInterval(90) {
            if abs(expiration.timeIntervalSince(viewBased)) <= 90 || expiration < viewBased {
                return Result(rotatesAt: expiration, isEstimate: false, note: nil)
            }
        }
        if firstView != nil {
            return jamfPeriod != nil
                ? Result(rotatesAt: viewBased, isEstimate: false, note: nil)
                : Result(rotatesAt: viewBased, isEstimate: true,
                         note: "Counted from the first view Jamf recorded, using the rotation period in the FleetHub settings.")
        }
        return Result(rotatesAt: fallback, isEstimate: true,
                      note: "Estimated from now. Jamf has not recorded a view of this password yet.")
    }

    private static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

@Observable
@MainActor
final class SSHSessionState {
    let info: SSHSessionInfo
    var ended = false
    var endedMessage = ""

    /// Fetches the account's current password from Jamf, for `sudo`. nil
    /// when the operator's role may not view the local admin password.
    @ObservationIgnored let fetchPassword: (() async throws -> FetchedPassword)?
    /// Ends the session and closes its window. Set by the window manager.
    @ObservationIgnored var endSession: (() -> Void)?
    /// Closes a companion panel without ending anything. Set by the window manager.
    @ObservationIgnored var dismiss: (() -> Void)?
    /// Tells the window manager the panel's content height changed.
    @ObservationIgnored var resize: ((CGFloat) -> Void)?

    /// The account and rotation time, brought up to date by every fetch.
    var username: String
    var rotatesAt: Date?
    var rotationIsEstimate: Bool
    var rotationNote: String?
    /// The last password read, kept in memory only so the panel can show it
    /// on request. Dropped when it is due to rotate and when the panel closes.
    var password: String?
    var isRevealed = false
    var isRevealing = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    var isCopyingPassword = false
    /// Short result shown beside the button; cleared after a few seconds.
    var copyNote: String?
    var copyFailed = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// How long a copied password stays on the clipboard.
    static let clipboardLifetime: TimeInterval = 60

    init(info: SSHSessionInfo, fetchPassword: (() async throws -> FetchedPassword)? = nil,
         initialPassword: String? = nil) {
        self.info = info
        self.fetchPassword = fetchPassword
        self.username = info.username
        self.rotatesAt = info.rotatesAt
        self.rotationIsEstimate = info.rotationIsEstimate
        self.rotationNote = info.rotationNote
        self.password = initialPassword
        scheduleExpiry()
    }

    /// Takes a fresh read from Jamf: the password, and its rotation time.
    private func adopt(_ fetched: FetchedPassword) {
        username = fetched.username
        password = fetched.password
        rotatesAt = fetched.rotatesAt
        rotationIsEstimate = fetched.rotationIsEstimate
        rotationNote = fetched.rotationNote
        scheduleExpiry()
    }

    /// Once the password is due to rotate, the copy held here may be stale:
    /// hide it and drop it, so the next Show or Copy reads the current one.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let rotatesAt, password != nil else { return }
        let wait = rotatesAt.timeIntervalSinceNow
        expiryTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.forgetPassword()
        }
    }

    func forgetPassword() {
        expiryTask?.cancel()
        password = nil
        isRevealed = false
    }

    /// Shows or hides the password in the panel. Showing reads it from Jamf
    /// first when no current copy is held.
    func toggleReveal() {
        if isRevealed { isRevealed = false; return }
        if password != nil { isRevealed = true; return }
        guard let fetchPassword, !isRevealing else { return }
        isRevealing = true
        copyNote = nil
        Task {
            defer { isRevealing = false }
            do {
                adopt(try await fetchPassword())
                isRevealed = true
            } catch {
                copyFailed = true
                copyNote = "Could not get it from Jamf: \(error.localizedDescription)."
            }
        }
    }

    /// Puts the account's current password on the clipboard, marked so
    /// clipboard managers skip it, and removes it again after a minute
    /// unless something else has been copied since.
    func copyPassword() {
        guard let fetchPassword, !isCopyingPassword else { return }
        isCopyingPassword = true
        copyNote = nil
        Task {
            defer { isCopyingPassword = false }
            do {
                let fetched = try await fetchPassword()
                adopt(fetched)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(fetched.password, forType: .string)
                pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                let change = pasteboard.changeCount
                copyFailed = false
                copyNote = "Copied. Clears in \(Int(Self.clipboardLifetime)) seconds."
                clearTask?.cancel()
                clearTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.clipboardLifetime))
                    guard !Task.isCancelled else { return }
                    if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                    self?.copyNote = nil
                }
            } catch {
                copyFailed = true
                copyNote = "Could not get it from Jamf: \(error.localizedDescription)."
            }
        }
    }
}

@MainActor
final class SSHWindowManager: NSObject, NSWindowDelegate {
    static let shared = SSHWindowManager()

    private final class Entry {
        let window: NSWindow
        let session: SSHSession
        let state: SSHSessionState
        let terminal: LocalProcessTerminalView
        let relay: TerminalRelay
        var reminder: Task<Void, Never>?
        var finished = false

        init(window: NSWindow, session: SSHSession, state: SSHSessionState,
             terminal: LocalProcessTerminalView, relay: TerminalRelay) {
            self.window = window; self.session = session; self.state = state
            self.terminal = terminal; self.relay = relay
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var terminationObserver: NSObjectProtocol?

    /// Minutes before rotation at which the window asks for attention.
    static let warningLead: TimeInterval = 5 * 60

    var hasOpenSessions: Bool { !entries.isEmpty }

    func open(session: SSHSession, info: SSHSessionInfo, fetchPassword: (() async throws -> FetchedPassword)? = nil) {
        let state = SSHSessionState(info: info, fetchPassword: fetchPassword)

        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.055, green: 0.067, blue: 0.106, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1)

        let relay = TerminalRelay()
        terminal.processDelegate = relay

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "\(Branding.productName) SSH — \(info.deviceName)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.contentView = NSHostingView(rootView: SSHSessionView(state: state, terminal: terminal))
        window.delegate = self
        window.center()

        let entry = Entry(window: window, session: session, state: state, terminal: terminal, relay: relay)
        // Closing the window is what ends the session (see windowWillClose).
        state.endSession = { [weak window] in window?.close() }
        entries[ObjectIdentifier(window)] = entry
        relay.onTerminated = { [weak self, weak entry] exitCode in
            guard let self, let entry else { return }
            self.sessionEnded(entry, exitCode: exitCode)
        }

        let command = session.terminalCommand
        terminal.startProcess(executable: command.executable, args: command.arguments)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)

        scheduleReminder(for: entry)
        observeTermination()
    }

    /// Brings the window forward shortly before the password rotates.
    private func scheduleReminder(for entry: Entry) {
        guard let rotatesAt = entry.state.info.rotatesAt else { return }
        let wait = rotatesAt.timeIntervalSinceNow - Self.warningLead
        guard wait > 0 else { return }
        entry.reminder = Task { [weak entry] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let entry, !entry.finished else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func sessionEnded(_ entry: Entry, exitCode: Int32?) {
        guard !entry.finished else { return }
        entry.finished = true
        entry.reminder?.cancel()
        entry.state.endedMessage = exitCode == 0 || exitCode == nil
            ? "The session has ended. You can close this window."
            : "The connection closed (ssh exit code \(exitCode ?? -1)). You can close this window."
        entry.state.ended = true
        log(entry)
        let session = entry.session
        Task.detached { session.close() }
    }

    private func log(_ entry: Entry) {
        let info = entry.state.info
        let minutes = max(1, Int(Date().timeIntervalSince(info.startedAt) / 60))
        ActionLogService.shared.logAction(
            actionName: "SSH Session Ended (\(minutes) min)",
            actionCategory: "Device Actions",
            deviceName: info.deviceName,
            deviceSerialNumber: info.serialNumber,
            deviceId: info.deviceID,
            ipAddressUsed: info.host,
            success: true
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // A Screen Share panel: closing it only closes the panel. The
        // session carries on in Apple's Screen Sharing window.
        if let panel = panels.removeValue(forKey: ObjectIdentifier(window)) {
            panel.reminder?.cancel()
            panel.state.forgetPassword()
            return
        }
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.reminder?.cancel()
        if !entry.finished {
            entry.finished = true
            entry.terminal.terminate()
            log(entry)
            let session = entry.session
            Task.detached { session.close() }
        }
    }

    // MARK: - Screen Share companion panel

    /// Apple's Screen Sharing app, which draws the remote screen.
    static let screenSharingBundleID = "com.apple.ScreenSharing"

    private final class PanelEntry {
        let panel: NSPanel
        let state: SSHSessionState
        var reminder: Task<Void, Never>?
        var logged = false
        init(panel: NSPanel, state: SSHSessionState) { self.panel = panel; self.state = state }
    }

    private var panels: [ObjectIdentifier: PanelEntry] = [:]
    private var screenSharingObserver: NSObjectProtocol?

    static func panelTitle(for info: SSHSessionInfo) -> String {
        let kind: String
        switch info.kind {
        case .localAdminPassword: kind = "Local Admin Password"
        case .fileVaultKey: kind = "FileVault Recovery Key"
        case .ssh, .screenShare: kind = "Screen Share"
        }
        return "\(Branding.productName) \(kind) — \(info.deviceName)"
    }

    /// Opens the FleetHub companion panel for a Screen Share session: device,
    /// password rotation countdown, session time, Copy Password and End
    /// Session. It floats beside Apple's Screen Sharing window.
    func openScreenSharePanel(info: SSHSessionInfo, fetchPassword: (() async throws -> FetchedPassword)?) {
        openCompanionPanel(info: info, fetchPassword: fetchPassword, initialPassword: nil)
        observeScreenSharing()
    }

    /// Opens the same panel for the Local Admin Password action. It holds
    /// the password just read, hidden until Show is clicked.
    func openPasswordPanel(info: SSHSessionInfo, password: String,
                           fetchPassword: (() async throws -> FetchedPassword)?) {
        openCompanionPanel(info: info, fetchPassword: fetchPassword, initialPassword: password)
    }

    private func openCompanionPanel(info: SSHSessionInfo, fetchPassword: (() async throws -> FetchedPassword)?,
                                    initialPassword: String?) {
        let state = SSHSessionState(info: info, fetchPassword: fetchPassword, initialPassword: initialPassword)
        let panel = CompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: CompanionPanelView.width, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // No title bar: the rounded card is the whole panel. The title is
        // still what VoiceOver and the Window menu name it by.
        panel.title = Self.panelTitle(for: info)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CompanionPanelView(state: state))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.delegate = self

        // Top right of the main screen, clear of the menu bar; each further
        // panel sits to the left of the last.
        if let visible = NSScreen.main?.visibleFrame {
            let offset = CGFloat(panels.count) * (panel.frame.width + 12)
            let x = max(visible.minX + 16, visible.maxX - panel.frame.width - 16 - offset)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: visible.maxY - 16))
        }

        let entry = PanelEntry(panel: panel, state: state)
        panels[ObjectIdentifier(panel)] = entry
        state.dismiss = { [weak panel] in panel?.close() }
        // Keeps the top edge where it is, so the card grows downwards.
        // Done after the current layout pass, never inside it: resizing a
        // window from its own layout would start another pass.
        state.resize = { [weak panel] height in
            DispatchQueue.main.async {
                guard let panel, height > 0, abs(panel.frame.height - height) >= 1 else { return }
                let top = panel.frame.maxY
                panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height),
                               display: true)
                panel.invalidateShadow()
            }
        }
        state.endSession = { [weak self, weak entry] in
            guard let self, let entry else { return }
            if entry.state.info.kind == .screenShare {
                self.endScreenShare(entry)
            } else {
                entry.panel.close()
            }
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        if let rotatesAt = info.rotatesAt {
            let wait = rotatesAt.timeIntervalSinceNow - Self.warningLead
            if wait > 0 {
                entry.reminder = Task { [weak entry] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let entry, !entry.state.ended else { return }
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    /// End Session: quits Apple's Screen Sharing app, which closes every
    /// Screen Sharing session it has open, then closes the panel.
    private func endScreenShare(_ entry: PanelEntry) {
        if !entry.state.ended {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.screenSharingBundleID)
                .forEach { $0.terminate() }
            logScreenShareEnd(entry)
        }
        entry.panel.close()
    }

    private func logScreenShareEnd(_ entry: PanelEntry) {
        guard !entry.logged else { return }
        entry.logged = true
        entry.reminder?.cancel()
        let info = entry.state.info
        let minutes = max(1, Int(Date().timeIntervalSince(info.startedAt) / 60))
        ActionLogService.shared.logAction(
            actionName: "Screen Share Session Ended (\(minutes) min)",
            actionCategory: "Device Actions",
            deviceName: info.deviceName,
            deviceSerialNumber: info.serialNumber,
            deviceId: info.deviceID,
            ipAddressUsed: info.host,
            success: true
        )
    }

    /// When Screen Sharing quits, by any route, every panel shows that its
    /// session is over.
    private func observeScreenSharing() {
        guard screenSharingObserver == nil else { return }
        screenSharingObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SSHWindowManager.screenSharingBundleID else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in self.panels.values where entry.state.info.kind == .screenShare && !entry.state.ended {
                    entry.state.endedMessage = "Screen Sharing has closed. You can close this panel."
                    entry.state.ended = true
                    self.logScreenShareEnd(entry)
                }
            }
        }
    }

    #if DEBUG
    /// Test aids for the DEBUG-only SSH window test.
    func debugType(_ text: String) {
        entries.values.forEach { $0.terminal.send(txt: text) }
    }
    func debugCopyPassword() {
        entries.values.forEach { $0.state.copyPassword() }
    }
    func debugRevealAll() {
        panels.values.forEach { $0.state.toggleReveal() }
    }
    func debugCloseAll() {
        // Through the End Session button's own action.
        entries.values.map(\.state).forEach { $0.endSession?() }
    }
    #endif

    /// Quitting FleetHub must not leave a signed-in connection behind.
    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in self.entries.values where !entry.finished {
                    entry.finished = true
                    entry.terminal.terminate()
                    entry.session.close()
                }
            }
        }
    }
}

/// A borderless panel cannot become key by default; this one must, so its
/// buttons and selectable text behave normally.
private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Receives the terminal's callbacks; only the end of the process matters.
private final class TerminalRelay: NSObject, LocalProcessTerminalViewDelegate {
    var onTerminated: (@MainActor (Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let handler = onTerminated
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(exitCode) }
        }
    }
}

private struct SSHTerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct SSHSessionView: View {
    let state: SSHSessionState
    let terminal: LocalProcessTerminalView?

    private var info: SSHSessionInfo { state.info }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The clock redraws once a second while a session is open.
            if !state.ended {
                TimelineView(.periodic(from: info.startedAt, by: 1)) { timeline in
                    rotationBar(now: timeline.date)
                }
            } else {
                notice(icon: "checkmark.circle", text: state.endedMessage,
                       ink: FleetHubTheme.muted, fill: FleetHubTheme.ground)
            }
            if let terminal {
                SSHTerminalHost(terminal: terminal)
                    .padding(.leading, 6)
                    .background(SwiftUI.Color(nsColor: terminal.nativeBackgroundColor))
            }
        }
        .background(FleetHubTheme.surface)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: info.deviceName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                Text(verbatim: "\(info.username.isEmpty ? "" : info.username + "@")\(info.host)\(info.viaVPN ? " · VPN" : "") · \(info.serialNumber)")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if !state.ended, state.fetchPassword != nil {
                copyPasswordControl
            }
            endSessionButton
            if !state.ended {
                TimelineView(.periodic(from: info.startedAt, by: 1)) { timeline in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Session Time")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.muted)
                        Text(verbatim: Self.clock(timeline.date.timeIntervalSince(info.startedAt)))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(FleetHubTheme.ink)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Disconnects and closes the window. Once the session has already
    /// ended on its own, it only closes the window.
    private var endSessionButton: some View {
        Button { state.endSession?() } label: {
            HStack(spacing: 6) {
                Image(systemName: state.ended ? "xmark" : "stop.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(state.ended ? "Close Window" : "End Session")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(state.ended ? FleetHubTheme.ink : FleetHubTheme.badText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(FleetHubTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(state.ended ? FleetHubTheme.border : FleetHubTheme.badText.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.ended ? "Close this window" : "Disconnect from this Mac and close the window")
        .padding(.trailing, 6)
    }

    /// Copies the account's current password for `sudo`. The password is
    /// fetched from Jamf at the moment of the click, so it is the current
    /// one even after a rotation, and it is never drawn on screen.
    private var copyPasswordControl: some View {
        HStack(spacing: 8) {
            if let note = state.copyNote {
                Text(verbatim: note)
                    .font(.system(size: 12))
                    .foregroundStyle(state.copyFailed ? FleetHubTheme.badText : FleetHubTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            Button { state.copyPassword() } label: {
                HStack(spacing: 6) {
                    if state.isCopyingPassword {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold))
                    }
                    Text("Copy Password").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(FleetHubTheme.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isCopyingPassword)
            .help(info.kind == .ssh
                  ? "Copies this account's current password for sudo. It is removed from the clipboard after a minute."
                  : "Copies the management account's current password, for signing in or an administrator prompt on the Mac. It is removed from the clipboard after a minute.")
        }
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func rotationBar(now: Date) -> some View {
        if let rotatesAt = state.rotatesAt {
            let remaining = rotatesAt.timeIntervalSince(now)
            let time = rotatesAt.formatted(date: .omitted, time: .shortened)
            let about = state.rotationIsEstimate ? "about " : ""
            if remaining <= 0 {
                notice(icon: "exclamationmark.triangle.fill",
                       text: info.kind == .ssh
                           ? "The password that opened this session was due to rotate at \(about)\(time). This session stays connected, but sudo and new sign-ins need the new password."
                           : "The password that signed this session in was due to rotate at \(about)\(time). This session stays connected, but signing in again needs the new password.",
                       ink: FleetHubTheme.badText, fill: FleetHubTheme.badFill)
            } else if remaining <= SSHWindowManager.warningLead {
                notice(icon: "clock.badge.exclamationmark",
                       text: info.kind == .ssh
                           ? "Password rotates in \(Self.clock(remaining)), at \(about)\(time). This session stays connected; sudo will need the new password after that."
                           : "Password rotates in \(Self.clock(remaining)), at \(about)\(time). This session stays connected.",
                       ink: FleetHubTheme.warnText, fill: FleetHubTheme.warnFill)
            } else {
                notice(icon: "clock",
                       text: "Password rotates in \(Self.clock(remaining)), at \(about)\(time).",
                       ink: FleetHubTheme.muted, fill: FleetHubTheme.ground)
            }
        } else if info.kind == .screenShare {
            notice(icon: "person.badge.key",
                   text: "No management account password was used to open this session.",
                   ink: FleetHubTheme.muted, fill: FleetHubTheme.ground)
        } else {
            notice(icon: "clock",
                   text: "Jamf rotates this account's password some time after it is used. The rotation time is not known for this session.",
                   ink: FleetHubTheme.muted, fill: FleetHubTheme.ground)
        }
    }

    private func notice(icon: String, text: String, ink: SwiftUI.Color, fill: SwiftUI.Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }

    /// 0:07, 12:45, 1:02:09.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Companion panel

/// The portrait FleetHub card that floats beside a Screen Share session, or
/// holds a Local Admin Password: device, a large countdown to the password's
/// rotation, the account, the password (hidden until asked for), Copy
/// Password, and End Session or Done.
struct CompanionPanelView: View {
    let state: SSHSessionState

    static let width: CGFloat = 300
    private static let radius: CGFloat = 24

    private var info: SSHSessionInfo { state.info }
    private var isScreenShare: Bool { info.kind == .screenShare }
    /// A recovery key does not rotate, so its panel has no countdown.
    private var isFileVaultKey: Bool { info.kind == .fileVaultKey }
    private var secretName: String { isFileVaultKey ? "Recovery Key" : "Password" }
    private var hasCredential: Bool { state.fetchPassword != nil || state.password != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            deviceBlock
            if state.ended {
                endedBlock
            } else if !isFileVaultKey {
                // The clock redraws once a second while the panel is open.
                TimelineView(.periodic(from: info.startedAt, by: 1)) { timeline in
                    VStack(spacing: 10) {
                        countdown(now: timeline.date)
                        if isScreenShare {
                            detailRow(label: "Session Time",
                                      value: SSHSessionView.clock(timeline.date.timeIntervalSince(info.startedAt)))
                        }
                    }
                }
            }
            if hasCredential, !state.ended {
                credentialBlock
                copyButton
            }
            if isFileVaultKey {
                fileVaultEntryHint
            }
            if !info.details.isEmpty {
                VStack(spacing: 8) {
                    ForEach(info.details, id: \.label) { detail in
                        detailRow(label: detail.label, value: detail.value,
                                  ink: detail.isGood == true ? FleetHubTheme.goodText
                                     : detail.isGood == false ? FleetHubTheme.warnText : FleetHubTheme.ink)
                    }
                }
            }
            closingButton
        }
        .padding(18)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(FleetHubTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .stroke(FleetHubTheme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        // The card takes the height its content needs, whatever the panel
        // offers, and the panel then follows it.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
            state.resize?(height)
        }
    }

    // MARK: Header

    private var titleRow: some View {
        HStack(spacing: 8) {
            BrandMark(size: 22)
            Text(isScreenShare ? "Screen Share" : isFileVaultKey ? "FileVault Recovery Key" : "Local Admin Password")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { state.dismiss?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FleetHubTheme.control)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FleetHubTheme.ground))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isScreenShare ? "Close this panel. The Screen Sharing session stays open." : "Close this panel")
            .accessibilityLabel("Close Panel")
        }
    }

    private var deviceBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: info.deviceName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if !info.host.isEmpty {
                    Text(verbatim: info.host)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(FleetHubTheme.muted)
                        .textSelection(.enabled)
                    if info.viaVPN {
                        Text("VPN")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SwiftUI.Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(FleetHubTheme.accentFill))
                    }
                }
            }
            Text(verbatim: info.serialNumber)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(FleetHubTheme.muted)
                .textSelection(.enabled)
        }
    }

    // MARK: Countdown

    @ViewBuilder
    private func countdown(now: Date) -> some View {
        if let rotatesAt = state.rotatesAt {
            let remaining = rotatesAt.timeIntervalSince(now)
            let due = remaining <= 0
            let soon = !due && remaining <= SSHWindowManager.warningLead
            let ink = due ? FleetHubTheme.badText : soon ? FleetHubTheme.warnText : FleetHubTheme.ink
            let fill = due ? FleetHubTheme.badFill : soon ? FleetHubTheme.warnFill : FleetHubTheme.ground
            let time = rotatesAt.formatted(date: .omitted, time: .shortened)
            VStack(spacing: 4) {
                Text(due ? "Password Rotation Due" : "Password Rotates In")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(due || soon ? ink : FleetHubTheme.muted)
                Text(verbatim: SSHSessionView.clock(remaining))
                    .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(due ? "Rotation is due" : "Time until the password rotates")
                    .accessibilityValue(SSHSessionView.clock(remaining))
                HStack(spacing: 6) {
                    Text(verbatim: due ? "Was due at \(time)" : "At \(time)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(due || soon ? ink : FleetHubTheme.muted)
                    if state.rotationIsEstimate {
                        Text("Estimated")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(FleetHubTheme.warnText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(FleetHubTheme.warnFill))
                            .overlay(Capsule().stroke(FleetHubTheme.warnText.opacity(0.25), lineWidth: 1))
                    }
                }
                if due {
                    Text(isScreenShare
                         ? "This session stays connected. Signing in again needs the new password."
                         : "Jamf replaces this password when the Mac next checks in. Copy Password reads the current one.")
                        .font(.system(size: 11))
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if let note = state.rotationNote {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(FleetHubTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill))
        } else {
            Text(isScreenShare
                 ? "No management account password was used to open this session."
                 : "The rotation time is not known for this password.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FleetHubTheme.ground))
        }
    }

    private var endedBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .semibold))
            Text(verbatim: state.endedMessage)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(FleetHubTheme.muted)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FleetHubTheme.ground))
    }

    // MARK: Credential

    private func detailRow(label: String, value: String, ink: SwiftUI.Color = FleetHubTheme.ink) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 2)
    }

    private var credentialBlock: some View {
        VStack(spacing: 0) {
            if !isFileVaultKey {
            credentialRow(label: "Account") {
                Text(verbatim: state.username.isEmpty ? "Shown After Copy" : state.username)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.username.isEmpty ? FleetHubTheme.muted : FleetHubTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } trailing: {
                EmptyView()
            }
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
            }
            credentialRow(label: secretName) {
                if state.isRevealed, let password = state.password {
                    Text(verbatim: password)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(FleetHubTheme.ink)
                        // A recovery key reads best on one line.
                        .lineLimit(isFileVaultKey ? 1 : nil)
                        .minimumScaleFactor(isFileVaultKey ? 0.8 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(verbatim: "••••••••••••")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FleetHubTheme.muted)
                        .accessibilityLabel("Hidden")
                }
            } trailing: {
                Button { state.toggleReveal() } label: {
                    Group {
                        if state.isRevealing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: state.isRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(FleetHubTheme.control)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isRevealing)
                .help(state.isRevealed ? "Hide the \(secretName.lowercased())" : "Show the \(secretName.lowercased())")
                .accessibilityLabel(state.isRevealed ? "Hide \(secretName)" : "Show \(secretName)")
            }
        }
        .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
            .fill(FleetHubTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
            .stroke(FleetHubTheme.border, lineWidth: 1))
    }

    private func credentialRow<Value: View, Trailing: View>(
        label: String, @ViewBuilder value: () -> Value, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.muted)
                value()
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    // MARK: Buttons

    /// The password is read from Jamf at the moment of the click, so it is
    /// the current one even after a rotation.
    private var copyButton: some View {
        VStack(spacing: 6) {
            Button { state.copyPassword() } label: {
                HStack(spacing: 7) {
                    if state.isCopyingPassword {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.on.doc.fill").font(.system(size: 12, weight: .semibold))
                    }
                    Text(isFileVaultKey ? "Copy Recovery Key" : "Copy Password").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(SwiftUI.Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.accentFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isCopyingPassword || state.fetchPassword == nil)
            .help(isFileVaultKey
                  ? "Copies this Mac's recovery key. It is removed from the clipboard after a minute."
                  : "Copies the account's current password. It is removed from the clipboard after a minute.")

            // Room for two lines is always kept, so the panel does not change
            // size when the result of a copy appears.
            Text(verbatim: state.copyNote ?? "The clipboard is cleared after a minute.")
                .font(.system(size: 11))
                .foregroundStyle(state.copyNote != nil && state.copyFailed ? FleetHubTheme.badText : FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var closingButton: some View {
        let endsSession = isScreenShare && !state.ended
        Button { state.endSession?() } label: {
            HStack(spacing: 6) {
                if endsSession {
                    Image(systemName: "stop.circle.fill").font(.system(size: 12, weight: .semibold))
                }
                Text(endsSession ? "End Session" : isScreenShare ? "Close" : "Done")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(endsSession ? FleetHubTheme.badText : FleetHubTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(FleetHubTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(endsSession ? FleetHubTheme.badText.opacity(0.35) : FleetHubTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(endsSession ? "Quit Screen Sharing and close this panel"
              : "Close this panel and forget the \(secretName.lowercased())")
    }

    // MARK: FileVault

    /// How to reach the recovery key field on the Mac itself. Apple documents
    /// Option-Shift-Return for Apple silicon on macOS 12.0.1 or later; macOS
    /// Recovery is the route when the field does not appear.
    private var fileVaultEntryHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("At the FileVault Login Screen")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
            HStack(spacing: 6) {
                keycap("⌥", name: "Option")
                keycap("⇧", name: "Shift")
                keycap("↩", name: "Return")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Press Option, Shift and Return together")
            Text("Option-Shift-Return")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
                .textSelection(.enabled)
            Text("Select the user, press these three keys together, type the recovery key, then press Return. If no key field appears, restart into macOS Recovery and enter the key there.")
                .font(.system(size: 11))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FleetHubTheme.ground))
    }

    private func keycap(_ symbol: String, name: String) -> some View {
        Text(symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(FleetHubTheme.ink)
            .frame(minWidth: 34, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FleetHubTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FleetHubTheme.border, lineWidth: 1))
            .help(name)
    }
}
