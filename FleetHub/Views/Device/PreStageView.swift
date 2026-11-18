//
//  PreStageView.swift
//  FleetHub
//
//  Pre-Stage registration tab — the single-device flow from
//  Device_Enrollment_Prep.sh as a form: asset tag + serial + PreStage in,
//  then a two-step run (Inventory Preload upsert → PreStage scope assign)
//  with per-step progress. Nothing touches a running Mac: both writes only
//  take effect at the device's next Automated Device Enrollment.
//
//  The PreStage picker is FILTERED by the signed-in user's role
//  capabilities (allowedPrestages / the reserved "all" literal), and the
//  same check is re-run at execution time — the picker is UI, never the
//  gate. A role granting no PreStages replaces the form with a notice
//  (fail-closed, like ABMLookupView's not-configured state). Every
//  attempt — success, failure, or denial — is written to the action log.
//
//  Serials are normalized (trimmed, uppercased) before any Jamf call;
//  JamfPreStageService normalizes again on its side, so the value shown
//  in the UI and the value sent to Jamf can never disagree.
//

import SwiftUI

// MARK: - Step State

/// One row of the two-step progress list.
private enum PreStageStepState {
    case pending
    case running
    case success
    case failure
    /// Step never ran because an earlier step failed.
    case skipped
    /// Step failed in the informative, self-healing way (serial not yet
    /// synced from ABM) — orange, not red.
    case warning
}

// MARK: - Pre-Stage View

struct PreStageView: View {
    /// Observed so the PreStage picker re-filters (and the fail-closed
    /// notice appears/disappears) the moment a role change lands.
    @ObservedObject private var session = UserSession.shared

    // MARK: Form State

    @State private var assetTag = ""
    @State private var serialNumber = ""
    @State private var selectedPreStage: JamfPreStage?

    @FocusState private var isAssetTagFocused: Bool
    @FocusState private var isSerialFocused: Bool

    /// Page width; decides between the two-column and stacked layouts.
    @State private var pageWidth: CGFloat = 0

    // MARK: PreStage List State

    @State private var allPreStages: [JamfPreStage] = []
    @State private var isLoadingPreStages = false
    @State private var preStageLoadError: String?
    /// True once fetchPreStages() has completed successfully — the empty
    /// filtered list only means "role grants nothing" AFTER a real load.
    @State private var hasLoadedPreStages = false

    // MARK: Execution State

    @State private var isExecuting = false
    @State private var showProgress = false
    @State private var preloadStepState: PreStageStepState = .pending
    @State private var assignStepState: PreStageStepState = .pending
    /// Fatal outcome message (red card).
    @State private var flowError: String?
    /// serialNotEligible outcome message (orange card — informative, the
    /// preload record WAS saved and a retry after Jamf's sync will work).
    @State private var flowWarning: String?
    /// The PreStage name the CURRENT/most recent run used — the progress
    /// card renders this, never the live picker selection, so changing the
    /// picker after a run cannot relabel its steps.
    @State private var executedPreStageName: String?

    // Bulk CSV import (Inventory Preload only — no PreStage change)
    @State private var showingCSVImporter = false
    @State private var bulkParseResult: CSVPreloadParser.ParseResult?
    @State private var bulkFileName: String?
    @State private var bulkError: String?
    @State private var isBulkRunning = false
    @State private var bulkProgress: (done: Int, total: Int, serial: String)?
    @State private var bulkSummary: BulkSummary?
    /// True while the chosen CSV is being validated by Jamf before the
    /// Import button is exposed.
    @State private var isValidatingCSV = false
    /// CSV template download (Jamf's live /csv-template) → fileExporter.
    @State private var isDownloadingTemplate = false
    @State private var templateDocument: ExportDocument?
    @State private var showTemplateExporter = false

    struct BulkSummary {
        let created: Int
        let alreadyExisted: Int
        let failed: Int
        let skippedNoSerial: Int
        let skippedNoAssetTag: Int
        let duplicatesInFile: Int
        let totalRows: Int
    }
    /// Set only on full success — drives the green summary card.
    @State private var completedSummary: RegistrationSummary?

    private struct RegistrationSummary {
        let assetTag: String
        let serialNumber: String
        let preStageName: String
    }

    // MARK: - Derived Data

    /// The PreStages this user's roles permit. Recomputed on every body
    /// evaluation, so a capabilities change (observed via `session`)
    /// re-filters without a reload.
    private var filteredPreStages: [JamfPreStage] {
        allPreStages.filter { session.capabilities.canUsePrestage(named: $0.displayName) }
    }

    private var trimmedAssetTag: String {
        assetTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSerial: String {
        serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// All three inputs present AND the selection still permitted — a role
    /// change can invalidate a selection that is already made, and the
    /// button must go dark the moment it does.
    private var isFormValid: Bool {
        guard !trimmedAssetTag.isEmpty, !normalizedSerial.isEmpty,
              let prestage = selectedPreStage else { return false }
        return session.capabilities.canUsePrestage(named: prestage.displayName)
    }

    // MARK: - Body

    var body: some View {
        // Same page frame as the Devices tab. Single-device registration on
        // the left, bulk import on the right; stacked when the window is
        // too narrow for two readable columns.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoBanner

                if pageWidth >= 900 {
                    HStack(alignment: .top, spacing: 20) {
                        registrationColumn
                            .frame(maxWidth: .infinity, alignment: .top)
                        bulkImportCard
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    registrationColumn
                    bulkImportCard
                }
                // Bulk import needs no PreStage list — it writes preload
                // records only, so it renders in every load state.
            }
            .readWidth(into: $pageWidth)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(FleetHubTheme.ground.ignoresSafeArea())
        .task {
            // First entry only — Try Again drives subsequent loads.
            if !hasLoadedPreStages && !isLoadingPreStages {
                await loadPreStages()
            }
        }
        .fileImporter(
            isPresented: $showingCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleCSVSelection(result)
        }
        .fileExporter(
            isPresented: $showTemplateExporter,
            document: templateDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "inventory-preload-template"
        ) { _ in
            templateDocument = nil
        }
    }

    // MARK: - Registration Column

    /// Everything about registering ONE device: the form (or the state that
    /// replaces it), then the run's progress and outcome.
    @ViewBuilder
    private var registrationColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoadingPreStages && !hasLoadedPreStages {
                loadingCard
            } else if let error = preStageLoadError, !hasLoadedPreStages {
                errorCard(error: error)
            } else if hasLoadedPreStages && filteredPreStages.isEmpty {
                noPreStagesNotice
            } else if hasLoadedPreStages {
                formCard

                if showProgress {
                    progressCard
                }

                if let summary = completedSummary {
                    successCard(summary)
                } else if let warning = flowWarning {
                    warningCard(warning)
                } else if let error = flowError {
                    failureCard(error)
                }
            }
        }
    }

    // MARK: - Shared Pieces

    private func cardTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FleetHubTheme.control)
    }

    private func fieldBox(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
            .stroke(isFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
    }

    /// Tinted outcome card: title row, then whatever the outcome needs.
    private func outcomeCard<Content: View>(
        icon: String,
        title: String,
        ink: Color,
        fill: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(ink)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)
        )
        .textSelection(.enabled)
    }

    // MARK: - Bulk CSV Import

    /// Bulk Inventory Preload from a CSV — asset tags only, no PreStage
    /// change (matching the script's bulk mode). Rows are parsed with the
    /// same rules the script used; existing preload records are skipped.
    private var bulkImportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle(
                "Bulk CSV Import",
                subtitle: "Import Inventory Preload records (serial + asset tag) in bulk. No PreStage assignments are made in bulk."
            )

            Text("The CSV needs a Serial Number column; when a row's Asset Tag is blank, the Computer Name is used if it looks like an asset tag (SH/CH + 6 digits). Records that already exist are skipped.")
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            // Column guidance mirrors Jamf's inventory-preload CSV schema.
            Text("Required columns: **Serial Number** and **Device Type** (Computer, Mobile Device, or Unknown). Optional: **Asset Tag** — this is the value the bulk tool registers. Download the template below for your instance's exact header row; every file you choose is validated by Jamf before import.")
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = bulkProgress, isBulkRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(FleetHubTheme.accentFill)
                    Text("(\(progress.done)/\(progress.total)) \(progress.serial)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(FleetHubTheme.muted)
                }
            } else if let parsed = bulkParseResult, bulkSummary == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(bulkFileName ?? "CSV") parsed: \(parsed.totalDataRows) rows, \(parsed.rows.count) valid (\(parsed.skippedNoSerial) without a serial, \(parsed.skippedNoAssetTag) without a resolvable asset tag, \(parsed.duplicatesInFile) in-file duplicates).")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        let importBlocked = parsed.rows.isEmpty || isBulkRunning || isExecuting
                        Button {
                            Task { await runBulkImport(parsed) }
                        } label: {
                            SettingsButtonLabel(
                                text: "Import \(parsed.rows.count) Record\(parsed.rows.count == 1 ? "" : "s")",
                                kind: .primary
                            )
                            .opacity(importBlocked ? 0.45 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(importBlocked)

                        Button {
                            bulkParseResult = nil
                            bulkFileName = nil
                        } label: {
                            SettingsButtonLabel(text: "Cancel")
                        }
                        .buttonStyle(.plain)
                        // A live Cancel during the run would reset the card
                        // while the import task keeps writing records.
                        .disabled(isBulkRunning)
                    }
                }
            } else if let summary = bulkSummary {
                VStack(alignment: .leading, spacing: 0) {
                    Label(
                        summary.failed > 0 ? "Bulk Import Finished With Errors" : "Bulk Import Complete",
                        systemImage: summary.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(summary.failed > 0 ? FleetHubTheme.warnText : FleetHubTheme.goodText)
                    .padding(.bottom, 8)

                    bulkSummaryRow("Created", summary.created, FleetHubTheme.goodText)
                    bulkSummaryRow("Already Existed (Skipped)", summary.alreadyExisted, FleetHubTheme.muted)
                    if summary.failed > 0 { bulkSummaryRow("Failed", summary.failed, FleetHubTheme.badText) }
                    if summary.skippedNoSerial > 0 { bulkSummaryRow("Skipped — No Serial", summary.skippedNoSerial, FleetHubTheme.warnText) }
                    if summary.skippedNoAssetTag > 0 { bulkSummaryRow("Skipped — No Asset Tag", summary.skippedNoAssetTag, FleetHubTheme.warnText) }
                    if summary.duplicatesInFile > 0 { bulkSummaryRow("Duplicates in File", summary.duplicatesInFile, FleetHubTheme.warnText) }

                    Button {
                        bulkSummary = nil
                        bulkParseResult = nil
                        bulkFileName = nil
                        showingCSVImporter = true
                    } label: {
                        SettingsButtonLabel(text: "Import Another CSV", icon: "folder")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                }
            } else if isValidatingCSV {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Validating \(bulkFileName ?? "CSV") with Jamf…")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                }
            } else {
                let controlsBlocked = isBulkRunning || isExecuting || isDownloadingTemplate
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { bulkStartButtons(blocked: controlsBlocked) }
                    VStack(alignment: .leading, spacing: 8) { bulkStartButtons(blocked: controlsBlocked) }
                }
            }

            if let bulkError {
                Label(bulkError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.badText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .fleetHubCard()
    }

    @ViewBuilder
    private func bulkStartButtons(blocked: Bool) -> some View {
        Button {
            bulkError = nil
            showingCSVImporter = true
        } label: {
            SettingsButtonLabel(text: "Choose CSV…", kind: .primary, icon: "folder")
                .opacity(blocked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)

        Button {
            downloadTemplate()
        } label: {
            HStack(spacing: 8) {
                if isDownloadingTemplate {
                    ProgressView().controlSize(.small)
                }
                SettingsButtonLabel(
                    text: "Download Template",
                    icon: isDownloadingTemplate ? nil : "square.and.arrow.down"
                )
            }
            .opacity(blocked && !isDownloadingTemplate ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .help("Downloads Jamf's Inventory Preload CSV template for this instance (Serial Number, Device Type, and your extension-attribute columns).")
    }

    private func bulkSummaryRow(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(FleetHubTheme.ink)
            }
            .padding(.vertical, 8)
        }
    }

    private func handleCSVSelection(_ result: Result<[URL], Error>) {
        bulkError = nil
        bulkSummary = nil
        bulkParseResult = nil

        switch result {
        case .failure(let error):
            bulkError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let data: Data
            let parsed: CSVPreloadParser.ParseResult
            do {
                data = try Data(contentsOf: url)
                // UTF-8 first; legacy Excel exports (Windows-1252-ish) fall
                // back to Latin-1, which decodes any byte sequence — serials
                // and asset tags are ASCII either way.
                guard let content = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                parsed = try CSVPreloadParser.parse(content)
            } catch {
                bulkError = "Could not read the CSV: \(error.localizedDescription)"
                return
            }

            bulkFileName = url.lastPathComponent
            // Jamf validates the file before we expose the Import button.
            validateThenStage(parsed, rawData: data, filename: url.lastPathComponent)
        }
    }

    /// Runs the chosen CSV through Jamf's csv-validate endpoint, then either
    /// exposes the Import button (valid) or blocks with Jamf's problem detail
    /// (invalid). If the validator itself can't be reached, we fall back to
    /// the local parse with a warning rather than blocking on infrastructure.
    private func validateThenStage(_ parsed: CSVPreloadParser.ParseResult, rawData: Data, filename: String) {
        isValidatingCSV = true
        Task { @MainActor in
            defer { isValidatingCSV = false }
            do {
                let result = try await JamfPreStageService.shared.validateCSV(rawData, filename: filename)
                if result.isValid {
                    bulkParseResult = parsed
                } else {
                    bulkParseResult = nil
                    bulkError = "Jamf rejected this CSV: \(result.detail ?? "no detail provided"). Fix the file (see the template) and choose it again."
                }
            } catch {
                // Validator unreachable (network/token): proceed on the local
                // parse, but say we couldn't confirm with Jamf.
                bulkParseResult = parsed
                bulkError = "Couldn't reach Jamf's CSV validator (\(error.localizedDescription)) — proceeding with local checks only."
            }
        }
    }

    /// Fetches Jamf's live Inventory Preload CSV template and hands it to the
    /// file exporter so the operator can save it and fill it in.
    private func downloadTemplate() {
        guard !isDownloadingTemplate else { return }
        bulkError = nil
        isDownloadingTemplate = true
        Task { @MainActor in
            defer { isDownloadingTemplate = false }
            do {
                let data = try await JamfPreStageService.shared.downloadCSVTemplate()
                templateDocument = ExportDocument(data: data)
                showTemplateExporter = true
            } catch {
                bulkError = "Couldn't download the template from Jamf: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func runBulkImport(_ parsed: CSVPreloadParser.ParseResult) async {
        guard !isBulkRunning else { return }
        isBulkRunning = true
        defer { isBulkRunning = false }

        bulkError = nil  // a prior run's error must never outlive this run

        var created = 0
        var existed = 0
        var failed = 0
        var consecutiveFailures = 0

        do {
            // Progress renders from the very start — the existing-records
            // sweep can take a while and must not look idle.
            bulkProgress = (0, parsed.rows.count, "Reading existing records…")
            let existingSerials = try await JamfPreStageService.shared.fetchAllPreloadSerials()

            for (index, row) in parsed.rows.enumerated() {
                bulkProgress = (index + 1, parsed.rows.count, row.serialNumber)

                if existingSerials.contains(row.serialNumber) {
                    existed += 1
                    continue
                }
                do {
                    try await JamfPreStageService.shared.createPreloadRecord(
                        serial: row.serialNumber, assetTag: row.assetTag, deviceType: row.deviceType
                    )
                    created += 1
                    consecutiveFailures = 0
                } catch {
                    failed += 1
                    consecutiveFailures += 1
                    AppLog.error("❌ Bulk preload failed for \(row.serialNumber): \(error.localizedDescription)")
                    // Systemic failure (expired token, outage): stop burning
                    // a request-timeout per remaining row.
                    if consecutiveFailures >= 10 {
                        failed += parsed.rows.count - index - 1
                        bulkError = "Import aborted after 10 consecutive failures — the remaining rows were not attempted. Fix the underlying issue (see logs) and re-import; already-created records will be skipped."
                        break
                    }
                }
            }
        } catch {
            bulkError = "Could not read existing Inventory Preload records: \(error.localizedDescription)"
            bulkProgress = nil
            ActionLogService.shared.logAction(
                actionName: "Bulk Preload Import",
                actionCategory: "Pre-Stage",
                deviceName: bulkFileName ?? "CSV",
                deviceSerialNumber: "\(parsed.rows.count) rows",
                deviceId: bulkFileName ?? "CSV",
                success: false,
                errorMessage: "Aborted before import: \(error.localizedDescription)"
            )
            return
        }

        bulkProgress = nil
        bulkSummary = BulkSummary(
            created: created,
            alreadyExisted: existed,
            failed: failed,
            skippedNoSerial: parsed.skippedNoSerial,
            skippedNoAssetTag: parsed.skippedNoAssetTag,
            duplicatesInFile: parsed.duplicatesInFile,
            totalRows: parsed.totalDataRows
        )
        bulkParseResult = nil

        ActionLogService.shared.logAction(
            actionName: "Bulk Preload Import",
            actionCategory: "Pre-Stage",
            deviceName: bulkFileName ?? "CSV",
            deviceSerialNumber: "\(parsed.rows.count) rows",
            deviceId: bulkFileName ?? "CSV",
            success: failed == 0,
            errorMessage: "created \(created), existed \(existed), failed \(failed), no-serial \(parsed.skippedNoSerial), no-asset \(parsed.skippedNoAssetTag), dups \(parsed.duplicatesInFile)"
        )
    }

    // MARK: - Data Loading

    /// Fetches the PreStage list. Filtering happens in `filteredPreStages`
    /// (not here) so a role change never requires a refetch.
    @MainActor
    private func loadPreStages() async {
        // Reentrancy guard: Try Again can be clicked while a fetch is
        // already in flight — never stack a second one.
        guard !isLoadingPreStages else { return }

        isLoadingPreStages = true
        preStageLoadError = nil

        do {
            allPreStages = try await JamfPreStageService.shared.fetchPreStages()
            hasLoadedPreStages = true
        } catch {
            preStageLoadError = error.localizedDescription
        }

        isLoadingPreStages = false
    }

    // MARK: - Registration Flow

    /// The two-step flow: Inventory Preload upsert, then PreStage scope
    /// assign. Step 1 failure stops the flow (step 2 is skipped — no
    /// PreStage change without its asset tag on record). Step 2 re-checks
    /// the role capability at execution time: the picker filtered the
    /// list, but the picker is never trusted. Every path audit-logs.
    @MainActor
    private func register() async {
        // Reentrancy guard: the button disables on isExecuting, but a
        // queued double-activation must still be a no-op.
        guard !isExecuting else { return }
        guard let prestage = selectedPreStage else { return }

        let serial = normalizedSerial
        let tag = trimmedAssetTag
        guard !serial.isEmpty, !tag.isEmpty else { return }

        // Reflect the normalization in the field so what the operator
        // sees is exactly what was sent.
        serialNumber = serial

        isExecuting = true
        defer { isExecuting = false }

        // Defense in depth FIRST — before ANY Jamf write. The filtered
        // picker is UI; this is the gate, and a denied attempt must not
        // leave a preload record behind.
        guard session.capabilities.canUsePrestage(named: prestage.displayName) else {
            showProgress = false
            flowError = "Your role does not permit assigning PreStage \"\(prestage.displayName)\". Nothing was changed."
            logAttempt(serial: serial, success: false,
                       error: "Denied by role capabilities: PreStage \"\(prestage.displayName)\" is not in allowedPrestages")
            return
        }

        // Freeze the names this run displays/logs — the picker stays live
        // behind the progress card and must not relabel a finished run.
        executedPreStageName = prestage.displayName

        showProgress = true
        preloadStepState = .running
        assignStepState = .pending
        flowError = nil
        flowWarning = nil
        completedSummary = nil

        // Step 1 — Inventory Preload upsert (asset tag on record first).
        do {
            try await JamfPreStageService.shared.upsertInventoryPreload(serial: serial, assetTag: tag)
            preloadStepState = .success
        } catch {
            preloadStepState = .failure
            assignStepState = .skipped
            flowError = "Saving the Inventory Preload record failed: \(error.localizedDescription)"
            logAttempt(serial: serial, success: false,
                       error: "Inventory Preload upsert failed: \(error.localizedDescription)")
            return
        }

        do {
            try await JamfPreStageService.shared.assign(serial: serial, toPreStage: prestage.id)
            assignStepState = .success
            completedSummary = RegistrationSummary(
                assetTag: tag,
                serialNumber: serial,
                preStageName: prestage.displayName
            )
            logAttempt(serial: serial, success: true,
                       error: "Assigned PreStage \"\(prestage.displayName)\" • asset tag \(tag)")
        } catch let error as PreStageError {
            if case .serialNotEligible = error {
                // Informative, not fatal: Jamf's ~2-minute ADE sync has not
                // picked the serial up yet. The service's message explains;
                // show it verbatim. The preload record from step 1 stands.
                assignStepState = .warning
                flowWarning = error.errorDescription
                    ?? "Jamf Pro does not yet recognize serial \(serial) as an ADE device."
                logAttempt(serial: serial, success: false, error: error.errorDescription)
            } else {
                assignStepState = .failure
                flowError = error.errorDescription ?? "PreStage assignment failed."
                logAttempt(serial: serial, success: false, error: error.errorDescription)
            }
        } catch {
            assignStepState = .failure
            flowError = error.localizedDescription
            logAttempt(serial: serial, success: false, error: error.localizedDescription)
        }
    }

    /// Resets the form for the next device. The PreStage list itself is
    /// kept — only inputs and outcome state clear.
    private func clearForm() {
        assetTag = ""
        serialNumber = ""
        selectedPreStage = nil
        showProgress = false
        preloadStepState = .pending
        assignStepState = .pending
        flowError = nil
        flowWarning = nil
        completedSummary = nil
        executedPreStageName = nil
    }

    private func logAttempt(serial: String, success: Bool, error: String?) {
        ActionLogService.shared.logAction(
            actionName: "PreStage Registration",
            actionCategory: "Pre-Stage",
            deviceName: serial,
            deviceSerialNumber: serial,
            deviceId: serial,
            success: success,
            errorMessage: error
        )
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))

            Text("Nothing changes on any Mac now — the asset tag and PreStage apply at the device's next ADE (re-)enrollment. Asset tags are saved to Jamf Inventory Preload; serials are stored uppercase.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .foregroundColor(FleetHubTheme.accent)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FleetHubTheme.accent.opacity(0.12))
        )
    }

    // MARK: - Form Card

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle(
                "Register a Device",
                subtitle: "Save the asset tag, then scope the serial to a PreStage for its next Automated Device Enrollment."
            )

            // Asset Tag
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Asset Tag")

                TextField("", text: $assetTag, prompt: Text("e.g. SH123456")
                    .foregroundColor(FleetHubTheme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.ink)
                    .focused($isAssetTagFocused)
                    .disabled(isExecuting)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .overlay(fieldBox(isFocused: isAssetTagFocused))
            }

            // Serial Number
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Serial Number")

                TextField("", text: $serialNumber, prompt: Text("e.g. C02XXXXXXXXX")
                    .foregroundColor(FleetHubTheme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.ink)
                    .focused($isSerialFocused)
                    .disabled(isExecuting)
                    .onSubmit {
                        // Normalize in place so the operator sees exactly
                        // what will be sent (register() normalizes again).
                        serialNumber = normalizedSerial
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .overlay(fieldBox(isFocused: isSerialFocused))
            }

            // PreStage picker
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("PreStage")

                preStageMenu
            }

            // Register button
            HStack {
                Spacer()

                let isBlocked = !isFormValid || isExecuting || isBulkRunning
                Button {
                    Task { await register() }
                } label: {
                    HStack(spacing: 8) {
                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                        SettingsButtonLabel(
                            text: isExecuting ? "Registering…" : "Register",
                            kind: .primary,
                            icon: isExecuting ? nil : "shippingbox.and.arrow.backward"
                        )
                    }
                    .opacity(isBlocked && !isExecuting ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isBlocked)
            }
        }
        .fleetHubCard()
    }

    /// Native pop-up button. A custom-styled `Menu` here read as static text no
    /// matter how much chrome was layered on, so this uses the real AppKit
    /// pop-up control (same pattern as `PreStageAssignmentSheet`) — it draws
    /// its own bezel and disclosure arrows, so it is unmistakably clickable.
    private var preStageMenu: some View {
        Picker("", selection: $selectedPreStage) {
            Text("Select a PreStage…").tag(JamfPreStage?.none)
            ForEach(filteredPreStages) { prestage in
                Text(prestage.displayName).tag(JamfPreStage?.some(prestage))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .disabled(isExecuting)
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registration Progress")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)

            VStack(spacing: 0) {
                stepRow(
                    title: "Saving Inventory Preload Record",
                    subtitle: nil,
                    state: preloadStepState
                )

                Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)

                stepRow(
                    title: "Assigning PreStage \(executedPreStageName ?? "")",
                    subtitle: assignStepState == .skipped ? "No PreStage change was made" : nil,
                    state: assignStepState
                )
            }
        }
        .fleetHubCard()
    }

    private func stepRow(title: String, subtitle: String?, state: PreStageStepState) -> some View {
        HStack(spacing: 12) {
            stepIcon(for: state)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(state == .pending || state == .skipped ? FleetHubTheme.muted : FleetHubTheme.ink)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func stepIcon(for state: PreStageStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FleetHubTheme.muted)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FleetHubTheme.goodText)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FleetHubTheme.badText)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FleetHubTheme.muted)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FleetHubTheme.warnText)
        }
    }

    // MARK: - Outcome Cards

    private func successCard(_ summary: RegistrationSummary) -> some View {
        outcomeCard(
            icon: "checkmark.circle.fill",
            title: "Device Registered",
            ink: FleetHubTheme.goodText,
            fill: FleetHubTheme.goodFill
        ) {
            VStack(spacing: 6) {
                summaryRow(label: "Asset Tag", value: summary.assetTag)
                summaryRow(label: "Serial Number", value: summary.serialNumber)
                summaryRow(label: "PreStage", value: summary.preStageName)
            }

            Text("Both changes take effect at the device's next Automated Device Enrollment.")
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                clearForm()
            } label: {
                SettingsButtonLabel(text: "Register Another", icon: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FleetHubTheme.ink)
                .textSelection(.enabled)
        }
    }

    /// serialNotEligible outcome — informative, not fatal. The service's
    /// message (shown verbatim) explains Jamf's ~2-minute ADE sync; the
    /// operator retries the same form once it has run.
    private func warningCard(_ message: String) -> some View {
        outcomeCard(
            icon: "exclamationmark.triangle.fill",
            title: "PreStage Not Assigned Yet",
            ink: FleetHubTheme.warnText,
            fill: FleetHubTheme.warnFill
        ) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("The Inventory Preload record with the asset tag was saved. Once Jamf's sync has run, click Register again to complete the PreStage assignment.")
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureCard(_ message: String) -> some View {
        outcomeCard(
            icon: "xmark.circle.fill",
            title: "Registration Failed",
            ink: FleetHubTheme.badText,
            fill: FleetHubTheme.badFill
        ) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Loading / Error / Fail-Closed States

    private func stateCard<Actions: View>(
        icon: String,
        iconColor: Color = FleetHubTheme.muted,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(iconColor)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            actions()
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .fleetHubCard()
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading PreStages From Jamf Pro…")
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .fleetHubCard()
    }

    private func errorCard(error: String) -> some View {
        stateCard(
            icon: "exclamationmark.triangle.fill",
            iconColor: FleetHubTheme.badText,
            title: "Unable to Load PreStages",
            message: error
        ) {
            Button {
                Task {
                    await loadPreStages()
                }
            } label: {
                SettingsButtonLabel(text: "Try Again", kind: .primary, icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isLoadingPreStages)
        }
    }

    /// Fail-closed: the load succeeded but the role's allowedPrestages
    /// permits none of them (or is absent). No form — mirroring
    /// ABMLookupView's not-configured notice.
    private var noPreStagesNotice: some View {
        stateCard(
            icon: "shippingbox",
            title: "No PreStages Available",
            message: allPreStages.isEmpty
                ? "No computer PreStage enrollments exist in Jamf Pro yet — there is nothing to register devices into."
                : "Your role does not grant any PreStages. Ask an administrator to add allowedPrestages to your role in the access profile."
        ) { EmptyView() }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Pre-Stage") {
    PreStageView()
        .frame(width: 1200, height: 800)
}
#endif
