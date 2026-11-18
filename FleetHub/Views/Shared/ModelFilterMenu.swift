//
//  ModelFilterMenu.swift
//  FleetHub
//
//  The Model filter used by device lists: a menu of the model types present
//  in the loaded devices, each with its device count, plus "All Models".
//
//  A model TYPE is the model name without its size/year qualifier, so
//  "MacBook Pro (14-inch, Nov 2023)" and "MacBook Pro (16-inch, 2021)" are
//  both "MacBook Pro", and "iPad Pro (11-inch) (4th generation)" is
//  "iPad Pro". Names with no qualifier ("iPhone 15 Pro") are their own type.
//  The exact model is still reachable through the search box.
//

import SwiftUI

extension DeviceListItem {
    /// The model type this device belongs to (see the file header).
    var modelType: String { ModelFilter.type(of: model) }
}

enum ModelFilter {
    static let unknown = "Unknown Model"

    static func type(of model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let qualifier = name.range(of: " (") {
            name = String(name[..<qualifier.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "N/A" || name == "Unknown" ? unknown : name
    }

    struct Option: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// The model types present in `devices`, A–Z (numeric-aware, so
    /// "iPhone 9" precedes "iPhone 15"), with "Unknown Model" last.
    static func options(in devices: [DeviceListItem]) -> [Option] {
        var counts: [String: Int] = [:]
        for device in devices { counts[device.modelType, default: 0] += 1 }
        return counts.map { Option(name: $0.key, count: $0.value) }.sorted { left, right in
            if (left.name == unknown) != (right.name == unknown) { return right.name == unknown }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

/// The Model filter control. `selection` nil means All Models.
struct ModelFilterMenu: View {
    let options: [ModelFilter.Option]
    @Binding var selection: String?
    var height: CGFloat = 36

    private var total: Int { options.reduce(0) { $0 + $1.count } }

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                HStack {
                    Text("All Models (\(total.formatted()))")
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            if !options.isEmpty {
                Divider()
                ForEach(options) { option in
                    Button {
                        selection = option.name
                    } label: {
                        HStack {
                            Text("\(option.name) (\(option.count.formatted()))")
                            if selection == option.name { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selection == nil ? FleetHubTheme.muted : FleetHubTheme.accent)
                Text(selection ?? "All Models")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            .foregroundStyle(FleetHubTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(selection == nil ? FleetHubTheme.border : FleetHubTheme.accent.opacity(0.6), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .help("Filter by model type")
        .accessibilityLabel("Model filter")
        .accessibilityValue(selection ?? "All Models")
    }
}
