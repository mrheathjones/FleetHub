//
//  SetupTheme.swift
//  FleetHubSetup
//
//  FleetHub's palette and the few controls Setup is built from. Setup is a
//  separate, standalone app, so it carries its own copy of the tokens rather
//  than linking the main app's managed-configuration code.
//

import SwiftUI
import AppKit

enum SetupTheme {
    static let ground = Color(light: 0xF3F5F9, dark: 0x0E1117)
    static let surface = Color(light: 0xFFFFFF, dark: 0x171B24)
    static let trough = Color(light: 0xE9EDF4, dark: 0x0A0D13)
    static let border = Color(light: 0xE3E7EF, dark: 0x262C38)
    static let ink = Color(light: 0x111827, dark: 0xF2F4F8)
    static let muted = Color(light: 0x5B6475, dark: 0xA3ACBD)
    static let control = Color(light: 0x3B4558, dark: 0xC5CCDA)
    static let accent = Color(light: 0x2952E3, dark: 0x7C96FF)
    static let accentFill = Color(light: 0x2952E3, dark: 0x3D63F0)
    static let accentSoft = Color(light: 0xE7EDFF, dark: 0x1A2347)
    /// Text on `accentSoft`: pills and informational notes.
    static let accentInk = Color(light: 0x1E3A9E, dark: 0xAFC1FF)
    /// Outline of fields and outlined buttons.
    static let fieldBorder = Color(light: 0xD5DBE6, dark: 0x343C4C)
    /// Hairline between rows inside a card.
    static let rowLine = Color(light: 0xEEF1F6, dark: 0x222835)
    /// Neutral pill fill.
    static let pill = Color(light: 0xEEF1F6, dark: 0x222835)
    /// Step number of a finished step.
    static let done = Color(light: 0x0E7A4B, dark: 0x1F9A63)
    /// The dark settings-preview panel, the same in both appearances.
    static let previewPanel = Color(light: 0x111827, dark: 0x0A0D13)
    static let previewWell = Color(light: 0x0B1220, dark: 0x05070B)
    static let previewText = Color(light: 0xD5DCEA, dark: 0xD5DCEA)

    static let goodText = Color(light: 0x0B6B41, dark: 0x6FD8A5)
    static let goodFill = Color(light: 0xE4F5EC, dark: 0x12301F)
    static let warnText = Color(light: 0x6B4A12, dark: 0xF2C26B)
    static let warnFill = Color(light: 0xFFF4DE, dark: 0x3A2A0C)
    static let badText = Color(light: 0x9B1C15, dark: 0xFF9C94)
    static let badFill = Color(light: 0xFDE7E5, dark: 0x3D1513)

    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Card

struct SetupCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: SetupTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SetupTheme.cardRadius, style: .continuous).stroke(SetupTheme.border))
    }
}

// MARK: - Buttons

enum SetupButtonKind { case primary, secondary, quiet }

struct SetupButton: View {
    let title: String
    var icon: String?
    var kind: SetupButtonKind = .secondary
    var isBusy = false
    var disabled = false
    /// The 48pt footer size used for Back and Continue.
    var large = false
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: large ? 15 : 14, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, kind == .quiet ? 0 : (large ? (kind == .primary ? 24 : 20) : 14))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: large ? 48 : 44)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: large ? 13 : SetupTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: large ? 13 : SetupTheme.controlRadius, style: .continuous)
                    .stroke(kind == .secondary ? SetupTheme.fieldBorder : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isBusy)
        .opacity(disabled ? 0.45 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: SetupTheme.ink
        case .quiet: SetupTheme.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: SetupTheme.accentFill
        case .secondary: SetupTheme.surface
        case .quiet: .clear
        }
    }
}

// MARK: - Fields

struct SetupField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var help: String?
    var secure = false
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(verbatim: placeholder))
                } else {
                    TextField("", text: $text, prompt: Text(verbatim: placeholder))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: monospaced ? .monospaced : .default))
            .foregroundStyle(SetupTheme.ink)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous).stroke(SetupTheme.fieldBorder))
            if let help {
                Text(help).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SetupToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupTheme.ink)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(SetupTheme.accentFill)
        }
    }
}

struct SetupStepperRow: View {
    let title: String
    var detail: String?
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupTheme.ink)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(SetupTheme.ink)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// A row of mutually exclusive choices drawn as a segmented trough: the
/// selected segment is a raised white tile.
struct SetupSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// Segments share the full width equally (inside a form card).
    var fill = false
    /// The darker trough used on the page ground; cards use the lighter one.
    var onGround = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? SetupTheme.ink : SetupTheme.control)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? SetupTheme.surface : .clear)
                                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(onGround ? SetupTheme.trough : SetupTheme.ground,
                    in: RoundedRectangle(cornerRadius: onGround ? 14 : 12, style: .continuous))
    }
}

// MARK: - Tags and notices

enum SetupTone { case neutral, good, warn, bad, accent }

struct SetupTag: View {
    let text: String
    var tone: SetupTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(colors.0)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(colors.1, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var colors: (Color, Color) {
        switch tone {
        case .neutral: (SetupTheme.control, SetupTheme.pill)
        case .good: (SetupTheme.goodText, SetupTheme.goodFill)
        case .warn: (SetupTheme.warnText, SetupTheme.warnFill)
        case .bad: (SetupTheme.badText, SetupTheme.badFill)
        case .accent: (SetupTheme.accentInk, SetupTheme.accentSoft)
        }
    }
}

/// A tinted paragraph, optionally opening with a bold lead-in.
struct SetupNotice: View {
    let text: String
    var tone: SetupTone = .neutral
    var lead: String?
    var icon: String?   // kept for call-site compatibility; the mock-up uses none

    var body: some View {
        (Text(lead.map { $0 + " " } ?? "").fontWeight(.bold) + Text(text))
            .font(.system(size: 13))
            .foregroundStyle(foreground)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .good: SetupTheme.goodText
        case .warn: SetupTheme.warnText
        case .bad: SetupTheme.badText
        case .accent: SetupTheme.accentInk
        case .neutral: SetupTheme.control
        }
    }

    private var fill: Color {
        switch tone {
        case .good: SetupTheme.goodFill
        case .warn: SetupTheme.warnFill
        case .bad: SetupTheme.badFill
        case .accent: SetupTheme.accentSoft
        case .neutral: SetupTheme.ground
        }
    }
}

/// The result box under a Test Connection button: a bold title over a line.
struct SetupStatusBox: View {
    let title: String
    let message: String
    var tone: SetupTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .bold))
            Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(tone == .good ? SetupTheme.goodText : tone == .bad ? SetupTheme.badText : SetupTheme.control)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .good ? SetupTheme.goodFill : tone == .bad ? SetupTheme.badFill : SetupTheme.ground,
                    in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
    }
}

/// The mark in Setup's top bar.
struct SetupLogo: View {
    var size: CGFloat = 30

    /// FleetHub Setup's own app icon: the FleetHub icon with a gear badge.
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Numbered how-to steps. `**bold**` marks interface names. A step can
/// carry a plain list (the privileges to add) shown in a grey box under it.
struct SetupHowTo: View {
    let steps: [String]
    var lists: [Int: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(SetupTheme.accentInk)
                        .frame(width: 24, height: 24)
                        .background(SetupTheme.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 8) {
                        Text((try? AttributedString(markdown: step)) ?? AttributedString(step))
                            .font(.system(size: 14)).foregroundStyle(SetupTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let list = lists[index] { SetupListBox(items: list) }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// Plain lines in a grey box: privilege and permission names.
struct SetupListBox: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(verbatim: item).font(.system(size: 13)).foregroundStyle(SetupTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupTheme.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A small label over a grey list box.
struct SetupPrivilegeList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
            SetupListBox(items: items)
        }
    }
}

/// The outlined "Copy Privilege List" button.
struct SetupCopyButton: View {
    let text: String
    var title = "Copy Privilege List"
    @State private var copied = false

    var body: some View {
        SetupButton(title: copied ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// A grid of on/off chips for picking capabilities.
struct SetupChipPicker: View {
    let options: [String]
    let titles: [String: String]
    @Binding var selection: Set<String>

    var body: some View {
        SetupFlow(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = selection.contains(option)
                Button {
                    if selected { selection.remove(option) } else { selection.insert(option) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selected ? "checkmark" : "plus").font(.system(size: 9.5, weight: .bold))
                        Text(titles[option] ?? option).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selected ? SetupTheme.accent : SetupTheme.control)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(selected ? SetupTheme.accentSoft : SetupTheme.ground, in: Capsule())
                    .overlay(Capsule().stroke(selected ? SetupTheme.accent.opacity(0.35) : SetupTheme.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Left-aligned wrapping layout.
struct SetupFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, maxX, y + rowHeight)
    }
}
