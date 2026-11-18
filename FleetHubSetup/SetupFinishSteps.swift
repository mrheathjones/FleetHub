//
//  SetupFinishSteps.swift
//  FleetHubSetup
//
//  Step 4: delivering the settings.
//

import SwiftUI

/// A card's 17pt title with a status pill beside it.
struct SetupCardHeading: View {
    let title: String
    let tag: String
    var tone: SetupTone = .neutral

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(SetupTheme.ink)
            SetupTag(text: tag, tone: tone)
        }
    }
}

// MARK: - Step 4 — Deliver

struct SetupDeliverStep: View {
    @EnvironmentObject private var model: SetupModel
    @State private var format: SetupOutputFormat = .profile
    @State private var message: SetupTestState = .idle
    @State private var uploads: [SetupDomain: SetupTestState] = [:]
    @State private var uploading = false

    private var canUpload: Bool { model.canUpload }

    private var uploadedAll: Bool {
        SetupDomain.allCases.allSatisfy { if case .passed = uploads[$0] { true } else { false } }
    }

    private var formatHint: String {
        switch format {
        case .profile: "A ready-to-upload configuration profile for each domain."
        case .plist: "A property list for each domain, to upload in an Application and Custom Settings payload."
        case .schema: "A custom schema for each domain, so the settings stay editable as a form in Jamf Pro."
        }
    }

    var body: some View {
        let problems = model.problems
        if !problems.isEmpty {
            SetupNotice(text: problems.joined(separator: "  "), tone: .warn, lead: "Still to fill in.")
        }

        filesCard

        HStack(alignment: .top, spacing: 16) {
            SetupCard {
                HStack {
                    Text("Configuration Profiles").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                    Spacer()
                    SetupTag(text: uploadedAll ? "Uploaded" : "Not Uploaded", tone: uploadedAll ? .good : .neutral)
                }
                Text("Uploads four profiles to Jamf Pro through the Jamf Pro API. They arrive with no scope. A profile that already exists is updated and keeps its scope.")
                    .font(.system(size: 14)).foregroundStyle(SetupTheme.control)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(SetupDomain.allCases) { domain in
                    if let state = uploads[domain], state != .running, state != .idle {
                        SetupUploadLine(name: domain.title, state: state)
                    }
                }
                Spacer(minLength: 0)
                if canUpload {
                    SetupButton(title: uploadedAll ? "Upload Again" : "Upload to Jamf Pro", kind: .primary,
                                isBusy: uploading, large: true, fullWidth: true) { uploadAll() }
                } else {
                    SetupNotice(text: "To upload from here, enter the upload client in step 3, under Jamf Pro API › For Setup.",
                                tone: .neutral)
                    SetupButton(title: "Go to Jamf Environment Setup", large: true, fullWidth: true) {
                        model.step = .environment
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SetupCard {
                HStack {
                    Text("Blueprint").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                    Spacer()
                    SetupTag(text: "Coming Soon", tone: .warn)
                }
                Text("Delivery as a blueprint through the Jamf Platform API is planned for a later release. Use configuration profiles or the downloads for now.")
                    .font(.system(size: 14)).foregroundStyle(SetupTheme.control)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("Create Blueprint")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(SetupTheme.muted)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(SetupTheme.ground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(SetupTheme.fieldBorder))
                    .accessibilityLabel("Create Blueprint, not available yet")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("After This").font(.system(size: 15, weight: .bold))
            Text(afterText).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(SetupTheme.accentInk)
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var afterText: String {
        var text = "Scope the profiles to the Macs that run FleetHub, then install the FleetHub package."
        if model.api.usesPerUserClients, !model.provisionsClients {
            text += " Each person enters their own Jamf API client the first time they open FleetHub."
        }
        if model.provisionsClients {
            text += " The provisioning client secret reaches each Mac through the credential import policy from step 3, or is typed into FleetHub at first launch."
        }
        if model.api.usesPlatformIntegration || !model.platformClientID.trimmingCharacters(in: .whitespaces).isEmpty {
            text += " The Platform integration's secret travels the same way."
        }
        text += " When the profiles are in Jamf, disable or delete the “FleetHub Setup” upload client."
        return text
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Your Settings Files").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                Spacer()
                SetupSegmented(
                    options: [(.profile, ".mobileconfig"), (.plist, ".plist"), (.schema, "JSON Schema")],
                    selection: $format
                )
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            (Text(formatHint + " Core carries your API choice (") + Text("apiBackend").fontWeight(.bold)
             + Text(") and the Platform integration's identity (") + Text("platformAPI").fontWeight(.bold)
             + Text(": region, client ID, tenant ID, environment ID). No file contains a secret."))
                .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.bottom, 12)

            ForEach(SetupDomain.allCases) { domain in
                SetupRowLine()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(domain.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupTheme.ink)
                        Text(verbatim: SetupOutput.fileName(for: domain, format: format))
                            .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    statusTag(for: domain)
                    SetupButton(title: "Download", icon: "arrow.down.to.line") { export(domain) }
                        .accessibilityLabel("Download \(domain.title)")
                    if canUpload {
                        SetupButton(title: "Upload", icon: "arrow.up.to.line", isBusy: uploads[domain] == .running) {
                            Task { await upload(domain) }
                        }
                        .accessibilityLabel("Upload \(domain.title) to Jamf Pro")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }

            Rectangle().fill(SetupTheme.border).frame(height: 1)
            HStack(spacing: 12) {
                SetupTestResult(state: message)
                Spacer(minLength: 0)
                SetupButton(title: "Download All to a Folder…") { exportAll() }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(light: 0xF7F8FB, dark: 0x131720))
        }
        .background(SetupTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: SetupTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SetupTheme.cardRadius, style: .continuous).stroke(SetupTheme.border))
    }

    @ViewBuilder private func statusTag(for domain: SetupDomain) -> some View {
        if domain == .core, model.normalizedJamfURL.isEmpty {
            SetupTag(text: "Needs Settings", tone: .warn)
        } else if model.isCustomized(domain) {
            SetupTag(text: "Configured", tone: .good)
        } else {
            SetupTag(text: "Using Defaults", tone: .neutral)
        }
    }

    private func export(_ domain: SetupDomain) {
        do {
            let data = try SetupOutput.data(for: domain, format: format, model: model)
            if let url = try SetupOutput.save(data, suggestedName: SetupOutput.fileName(for: domain, format: format)) {
                message = .passed("Saved \(url.lastPathComponent).")
            }
        } catch {
            message = .failed(error.localizedDescription)
        }
    }

    private func exportAll() {
        do {
            if let folder = try SetupOutput.saveEverything(model: model) {
                message = .passed("Saved everything to \(folder.lastPathComponent).")
            }
        } catch {
            message = .failed(error.localizedDescription)
        }
    }

    private func upload(_ domain: SetupDomain) async {
        uploads[domain] = .running
        do {
            let profile = try SetupOutput.profile(for: [domain], model: model)
            let result = try await SetupConnection.uploadProfile(
                named: domain.profileName, profile: profile,
                jamfURL: model.normalizedJamfURL,
                clientID: model.uploadClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: model.uploadClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            uploads[domain] = .passed(result.updated
                ? "Updated profile \(result.profileID); scope unchanged."
                : "Created profile \(result.profileID), unscoped.")
        } catch {
            uploads[domain] = .failed(error.localizedDescription)
        }
    }

    private func uploadAll() {
        uploading = true
        Task {
            for domain in SetupDomain.allCases { await upload(domain) }
            uploading = false
        }
    }
}

/// One domain's upload outcome inside the Configuration Profiles card.
struct SetupUploadLine: View {
    let name: String
    let state: SetupTestState

    var body: some View {
        let failed: Bool = { if case .failed = state { true } else { false } }()
        let text: String = {
            switch state {
            case .passed(let message), .failed(let message): message
            default: ""
            }
        }()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failed ? "xmark" : "checkmark").font(.system(size: 10, weight: .heavy))
                .foregroundStyle(failed ? SetupTheme.badText : SetupTheme.goodText)
                .frame(width: 20, height: 20)
                .background(failed ? SetupTheme.badFill : SetupTheme.goodFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            (Text(name + ": ").fontWeight(.semibold) + Text(text))
                .font(.system(size: 13)).foregroundStyle(SetupTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
