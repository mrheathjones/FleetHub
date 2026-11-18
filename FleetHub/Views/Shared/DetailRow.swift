//
//  DetailRow.swift
//  FleetHub
//
//  Label/value row for a DetailCard. A nil value renders as "N/A".
//

import SwiftUI

struct DetailRow: View {
    let label: String
    let value: String?
    var monospaced: Bool = false

    init(_ label: String, _ value: String?, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    /// Set by a narrow card (see `detailRowsStacked()`): the label sits
    /// above its value instead of beside it.
    @Environment(\.detailRowsStacked) private var isStacked

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    labelText
                        .frame(width: 170, alignment: .leading)
                    valueText
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 9)
        // Hairline UNDER each row, so nothing sits between the card title
        // and its first row. DetailCard trims the line under the last row.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FleetHubTheme.border)
                .frame(height: 1)
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: isStacked ? 12 : 13))
            .foregroundColor(FleetHubTheme.muted)
            .textSelection(.enabled)
    }

    private var valueText: some View {
        Text(value ?? "N/A")
            .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundColor(FleetHubTheme.ink)
            .textSelection(.enabled)
    }
}

// MARK: - Stacked rows

private struct DetailRowsStackedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var detailRowsStacked: Bool {
        get { self[DetailRowsStackedKey.self] }
        set { self[DetailRowsStackedKey.self] = newValue }
    }
}

extension View {
    /// Makes every `DetailRow` inside draw its label above its value — for
    /// cards too narrow to hold both side by side.
    func detailRowsStacked(_ stacked: Bool = true) -> some View {
        environment(\.detailRowsStacked, stacked)
    }
}
