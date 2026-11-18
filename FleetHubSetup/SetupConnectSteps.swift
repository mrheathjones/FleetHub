//
//  SetupConnectSteps.swift
//  FleetHubSetup
//
//  Step 1: the starting choices, plus the small pieces the other steps
//  share (choice cards, connection-test status).
//

import SwiftUI

// MARK: - Step 1 — Start

struct SetupStartStep: View {
    @EnvironmentObject private var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupSectionHeading(title: "How FleetHub Talks to Jamf",
                                subtitle: "Pick one. You can change it later by delivering a new Core profile.")
            HStack(alignment: .top, spacing: 14) {
                ForEach(SetupAPIChoice.allCases) { choice in
                    SetupChoiceCard(
                        title: choice.title, text: choice.summary, needs: choice.needs,
                        pill: model.api == choice ? "Selected" : "Not Selected",
                        pillTone: model.api == choice ? .accent : .neutral,
                        selected: model.api == choice
                    ) { model.api = choice }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            SetupNotice(text: model.apiNote, tone: .accent)
        }

        SetupSectionHeading(title: "How the Settings Reach Your Macs")

        HStack(alignment: .top, spacing: 14) {
            SetupChoiceCard(
                title: "Configuration Profiles",
                text: "Setup uploads one profile per settings domain to Jamf Pro. You scope them in Jamf Pro as usual.",
                needs: "Needs a Jamf Pro API client, entered in step 3.",
                pill: model.uploadProfiles ? "Selected" : "Not Selected",
                pillTone: model.uploadProfiles ? .accent : .neutral,
                selected: model.uploadProfiles
            ) { model.uploadProfiles.toggle() }
            SetupChoiceCard(
                title: "Blueprints",
                text: "Delivery as a blueprint through the Jamf Platform API is planned for a later release.",
                needs: "Not available yet.",
                pill: "Coming Soon", pillTone: .warn, selected: false, disabled: true
            ) {}
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Export Files Only").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupTheme.ink)
                Text("Always available. Download a .mobileconfig, .plist or JSON schema and upload it yourself. No API credentials needed.")
                    .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SetupButton(title: "Skip to Configure") { model.step = .configure }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SetupTheme.border))

        SetupCard("Have These Ready") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([
                    "Your Jamf Pro tenant URL and an account that can create API roles and clients.",
                    "For the Platform API or Compliance Benchmarks: a Jamf Account administrator who can create an API credential.",
                    "If you use Microsoft sign-in: your Entra tenant ID and the app registration's client ID."
                ], id: \.self) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(SetupTheme.accentFill).frame(width: 8, height: 8).padding(.top, 6)
                        Text(line).font(.system(size: 14)).foregroundStyle(SetupTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct SetupSectionHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.2).foregroundStyle(SetupTheme.ink)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
            }
        }
    }
}

/// A selectable card: title with a status pill, a paragraph, and what it needs.
struct SetupChoiceCard: View {
    let title: String
    let text: String
    let needs: String
    let pill: String
    let pillTone: SetupTone
    let selected: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.2).foregroundStyle(SetupTheme.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    SetupTag(text: pill, tone: pillTone).fixedSize()
                }
                Text(text).font(.system(size: 14)).foregroundStyle(SetupTheme.control)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Text(needs).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? SetupTheme.accentFill : SetupTheme.border, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Connection test state

enum SetupTestState: Equatable {
    case idle, running
    case passed(String)
    case failed(String)
}

/// The status box under a Test Connection button.
struct SetupTestStatus: View {
    let state: SetupTestState
    let untested: String

    var body: some View {
        switch state {
        case .idle: SetupStatusBox(title: "Not Tested Yet", message: untested)
        case .running: SetupStatusBox(title: "Testing…", message: "Asking Jamf for a token.")
        case .passed(let message): SetupStatusBox(title: "Connected", message: message, tone: .good)
        case .failed(let message): SetupStatusBox(title: "Not Connected", message: message, tone: .bad)
        }
    }
}

/// A one-line result for exports and uploads; nothing until there is one.
struct SetupTestResult: View {
    let state: SetupTestState

    var body: some View {
        switch state {
        case .idle, .running: EmptyView()
        case .passed(let message): SetupNotice(text: message, tone: .good)
        case .failed(let message): SetupNotice(text: message, tone: .bad)
        }
    }
}
