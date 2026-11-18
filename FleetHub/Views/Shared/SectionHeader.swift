//
//  SectionHeader.swift
//  FleetHub
//
//  Page-level heading for a device-detail section (icon + large title).
//

import SwiftUI

struct SectionHeader: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        // The icon is kept in the API for call sites but no longer drawn: the
        // tab and chip above already say which section this is.
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(FleetHubTheme.ink)
    }
}

// MARK: - Width Reading

extension View {
    /// Reports the width this view is given into `width`, so the owner can
    /// choose a layout in ITS OWN body.
    ///
    /// This replaces an earlier container that handed the width to a content
    /// closure: state read inside that closure was not tracked as a
    /// dependency of the owning view, so the content could show stale values
    /// until something else forced a refresh.
    func readWidth(into width: Binding<CGFloat>) -> some View {
        frame(maxWidth: .infinity)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { width.wrappedValue = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, newWidth in
                            width.wrappedValue = newWidth
                        }
                }
            )
    }
}
