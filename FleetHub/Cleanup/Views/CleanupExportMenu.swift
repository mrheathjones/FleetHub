//
//  CleanupExportMenu.swift
//  FleetHub
//
//  Reusable "Export" menu (CSV / Markdown / PDF) backed by the native file
//  exporter. Drops into any toolbar; the table is built lazily so PDF
//  rendering only happens on the chosen format.
//

import SwiftUI
import UniformTypeIdentifiers

/// A FileDocument whose bytes and type are supplied at export time.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .markdownReport, .pdf, .plainText, .excelWorkbook]
    static let writableContentTypes: [UTType] = [.commaSeparatedText, .markdownReport, .pdf, .plainText, .excelWorkbook]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
func exportData(_ table: ReportTable, as format: CleanupExportFormat) -> Data {
    switch format {
    case .csv: table.csvData()
    case .markdown: Data(table.markdownString().utf8)
    case .pdf: ReportPDF.render(table)
    }
}

struct CleanupExportMenu: View {
    /// Base filename without extension.
    let filename: String
    /// Built lazily when a format is chosen.
    let makeTable: () -> ReportTable
    var titleKey: String = "Export"

    @State private var document: ExportDocument?
    @State private var contentType: UTType = .commaSeparatedText
    @State private var isExporting = false
    /// Observed so the export gate re-evaluates when capabilities land
    /// after sign-in.
    @ObservedObject private var session = UserSession.shared

    var body: some View {
        // Every Cleanup export funnels through this menu, so the
        // allowExport gate lives here once: no grant, no control at all.
        if session.capabilities.allowExport {
            Menu {
                ForEach(CleanupExportFormat.allCases) { format in
                    Button {
                        prepare(format)
                    } label: {
                        Label(format.displayName, systemImage: format.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(titleKey)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(FleetHubTheme.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
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
            .fileExporter(
                isPresented: $isExporting,
                document: document,
                contentType: contentType,
                defaultFilename: filename
            ) { _ in
                document = nil
            }
        }
    }

    private func prepare(_ format: CleanupExportFormat) {
        // Defense in depth: the menu is not rendered without the grant, but
        // never let enforcement live only in the UI.
        guard session.capabilities.allowExport else { return }
        let table = makeTable()
        document = ExportDocument(data: exportData(table, as: format))
        contentType = format.utType
        isExporting = true
    }
}
