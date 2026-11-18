//
//  SearchBar.swift
//  FleetHub
//
//  Inline filter field with a clear button.
//

import SwiftUI

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String

    init(text: Binding<String>, placeholder: String) {
        self._text = text
        self.placeholder = placeholder
    }

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            // Verbatim prompt: a placeholder is never Markdown.
            TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundColor(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.ink)
                .focused($isFocused)
                .accessibilityLabel(placeholder)

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
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
    }
}
