//
//  FleetHubSetupApp.swift
//  FleetHubSetup
//
//  FleetHub Setup: a guided, four-step app for the Jamf admin. It collects
//  the non-secret settings FleetHub needs, shows which Jamf permissions each
//  FleetHub role requires, and exports — or uploads — the configuration
//  profiles that deliver those settings.
//
//  The window follows the design canvas: a top bar, a step list on the
//  left, and each step's page — heading, cards, then Back / Continue —
//  scrolling as one column.
//

import SwiftUI

@main
struct FleetHubSetupApp: App {
    @StateObject private var model = SetupModel()

    var body: some Scene {
        WindowGroup("FleetHub Setup") {
            SetupShellView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 860)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum SetupStep: Int, CaseIterable, Identifiable {
    case start, configure, environment, deliver
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .configure: "Configure"
        case .environment: "Jamf Environment Setup"
        case .deliver: "Deliver"
        }
    }

    var subtitle: String {
        switch self {
        case .start: "API and delivery"
        case .configure: "Your FleetHub settings"
        case .environment: "API clients and permissions"
        case .deliver: "Export or upload"
        }
    }

    var heading: String {
        switch self {
        case .start: "Set Up FleetHub for Your Organization"
        case .configure: "Configure FleetHub"
        case .environment: "Jamf Environment Setup"
        case .deliver: "Review and Deliver"
        }
    }

    var blurb: String {
        switch self {
        case .start: "Answer a few questions and leave with the settings FleetHub needs, ready for Jamf Pro. Start with two choices: which Jamf API FleetHub uses, and how the settings reach your Macs."
        case .configure: "Settings are grouped into four domains. Each becomes its own configuration profile. Core is required; the rest have working defaults."
        case .environment: "What to create in Jamf, and the permissions each credential needs. The lists are worked out from the API you chose and from what each FleetHub role can do."
        case .deliver: "Download the files, or let Setup put them in Jamf for you. Nothing is scoped to devices until you do it in Jamf."
        }
    }
}

struct SetupShellView: View {
    @EnvironmentObject private var model: SetupModel
    @State private var fileError: String?
    @State private var confirmingStartOver = false

    private var step: SetupStep { model.step }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(SetupTheme.border)
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    stepList.frame(width: 236)
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.heading)
                                .font(.system(size: 28, weight: .bold)).tracking(-0.6)
                                .foregroundStyle(SetupTheme.ink)
                            Text(step.blurb).font(.system(size: 15)).foregroundStyle(SetupTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        content
                        footer.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
                .frame(maxWidth: 1144)
                .frame(maxWidth: .infinity)
            }
            .id(step)
        }
        .background(SetupTheme.ground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SetupLogo(size: 40)
            Text("FleetHub Setup").font(.system(size: 17, weight: .bold)).tracking(-0.2)
                .foregroundStyle(SetupTheme.ink)
            Spacer()
            Text(saveStatus).font(.system(size: 12)).foregroundStyle(fileError == nil ? SetupTheme.muted : SetupTheme.badText)
                .lineLimit(1)
            SetupButton(title: "Open…", icon: "folder") { openFile() }
            SetupButton(title: "Save…", icon: "square.and.arrow.down") { saveFile() }
            SetupButton(title: "Start Over", kind: .quiet) { confirmingStartOver = true }
                .padding(.horizontal, 6)
            Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count)")
                .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
        .background(SetupTheme.surface)
        .confirmationDialog("Start over?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Clear Everything", role: .destructive) {
                model.startOver()
                fileError = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every setting entered in Setup is cleared, including the automatic save. Files you saved with Save… are not touched.")
        }
    }

    private var saveStatus: String {
        if let fileError { return fileError }
        if let saved = model.lastSaved {
            return "Saved automatically at \(saved.formatted(date: .omitted, time: .shortened))"
        }
        return model.restoredFromAutosave ? "Picked up where you left off" : "Saves automatically"
    }

    /// Saves the settings to a file the admin chooses, to keep or share.
    /// Secrets are never part of it.
    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FleetHub Setup.json"
        panel.canCreateDirectories = true
        panel.message = "Saves every setting except secrets, which are never written to disk."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.encodedSetup().write(to: url, options: .atomic)
            fileError = nil
        } catch {
            fileError = "Could not save: \(error.localizedDescription)"
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file saved from FleetHub Setup. It replaces the settings on screen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.load(from: try Data(contentsOf: url))
            fileError = nil
        } catch {
            fileError = "That file is not a FleetHub Setup save."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .start: SetupStartStep()
        case .configure: SetupConfigureStep()
        case .environment: SetupEnvironmentStep()
        case .deliver: SetupDeliverStep()
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SetupStep.allCases) { candidate in
                let current = candidate == step
                let done = candidate.rawValue < step.rawValue
                Button { model.step = candidate } label: {
                    HStack(spacing: 12) {
                        Text("\(candidate.rawValue + 1)")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(current || done ? .white : SetupTheme.control)
                            .frame(width: 28, height: 28)
                            .background(done ? SetupTheme.done : current ? SetupTheme.accentFill : SetupTheme.border,
                                        in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(candidate.title).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SetupTheme.ink).lineLimit(1).minimumScaleFactor(0.85)
                            Text(candidate.subtitle).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                    .background(current ? SetupTheme.surface : .clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let previous = SetupStep(rawValue: step.rawValue - 1) {
                SetupButton(title: "Back", large: true) { model.step = previous }
            } else {
                Text(model.startSummary).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
            }
            Spacer()
            if let next = SetupStep(rawValue: step.rawValue + 1) {
                SetupButton(title: "Continue", kind: .primary, large: true) { model.step = next }
            } else {
                SetupButton(title: "Finish", large: true) { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
