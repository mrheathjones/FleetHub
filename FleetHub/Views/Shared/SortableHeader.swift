//
//  SortableHeader.swift
//  FleetHub
//
//  The one sortable column header every table in the app uses, plus the
//  ordering behind it.
//
//  A table keeps a `TableSort<Key>` in @State, draws each column title with
//  `SortableHeaderText`, and sorts its rows with `rows.sorted(by:value:)`:
//
//      @State private var sort = TableSort<Column>()
//      …
//      SortableHeaderText("Version", key: .version, sort: $sort)
//      …
//      let shown = rows.sorted(by: sort) { row, column in
//          switch column {
//          case .name: .text(row.name)
//          case .version: .text(row.version)      // "10.2" sorts before "10.10"
//          case .size: .number(row.bytes)
//          case .installed: .date(row.installedAt)
//          }
//      }
//
//  Clicking a header sorts ascending; clicking it again sorts descending.
//  With no column chosen the rows keep the order they arrived in.
//
//  ORDERING RULES
//  • Strict weak ordering: descending is `precedes(b, a)`, never
//    `!precedes(a, b)` (which would call equal rows "before" each other).
//  • Stable: rows that compare equal keep their incoming order.
//  • Text compares the way Finder does — case-insensitive and
//    numeric-aware, so versions and "Mac 9" / "Mac 10" order correctly.
//  • Dates compare as dates and numbers as numbers, never as their text.
//  • Empty values sort LAST in both directions: a blank is "no answer",
//    not the smallest value.
//

import SwiftUI

/// Which column a table is sorted by, and which way.
struct TableSort<Key: Hashable>: Equatable {
    var key: Key?
    var ascending = true

    init(key: Key? = nil, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// A header click: a new column sorts ascending; the same column flips.
    mutating func toggle(_ column: Key) {
        if key == column {
            ascending.toggle()
        } else {
            key = column
            ascending = true
        }
    }
}

/// A cell's value as the sorter sees it.
enum SortValue {
    case text(String?)
    case number(Double?)
    case date(Date?)
    case flag(Bool?)

    /// Whole numbers (counts, IDs, byte sizes).
    static func int(_ value: Int?) -> SortValue { .number(value.map(Double.init)) }
    static func int(_ value: Int64?) -> SortValue { .number(value.map(Double.init)) }

    /// A date that arrives as text (ISO 8601, with or without fractional
    /// seconds or a time zone, or a bare `yyyy-MM-dd`). Text that is not a
    /// date sorts as empty, so it lands last instead of scattering.
    static func isoDate(_ text: String?) -> SortValue {
        .date(text.flatMap(SortDateParser.date(from:)))
    }

    /// True when there is nothing to compare: nil, blank text, or one of the
    /// placeholder dashes tables show for a missing value.
    var isEmpty: Bool {
        switch self {
        case .text(let value):
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty || trimmed == "—" || trimmed == "-" || trimmed == "–"
        case .number(let value): return value == nil || value?.isNaN == true
        case .date(let value): return value == nil
        case .flag(let value): return value == nil
        }
    }

    /// Ascending comparison of two non-empty values of the same kind.
    /// Returns nil when they are equal (or not comparable).
    fileprivate static func ascendingOrder(_ left: SortValue, _ right: SortValue) -> Bool? {
        switch (left, right) {
        case (.text(let a?), .text(let b?)):
            let result = a.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedStandardCompare(b.trimmingCharacters(in: .whitespacesAndNewlines))
            return result == .orderedSame ? nil : result == .orderedAscending
        case (.number(let a?), .number(let b?)):
            return a == b ? nil : a < b
        case (.date(let a?), .date(let b?)):
            return a == b ? nil : a < b
        case (.flag(let a?), .flag(let b?)):
            // false before true ascending ("No" before "Yes").
            return a == b ? nil : (!a && b)
        default:
            return nil
        }
    }
}

extension Array {
    /// The rows in the order `sort` asks for. See the file header for the
    /// ordering rules. With no column chosen the array is returned as is.
    func sorted<Key: Hashable>(by sort: TableSort<Key>, value: (Element, Key) -> SortValue) -> [Element] {
        guard let key = sort.key, count > 1 else { return self }
        // Decorate once: each row's value is computed a single time, and the
        // original index breaks ties so the sort is stable.
        let decorated = enumerated().map { (index: $0.offset, row: $0.element, value: value($0.element, key)) }
        let ordered = decorated.sorted { left, right in
            let leftEmpty = left.value.isEmpty
            let rightEmpty = right.value.isEmpty
            if leftEmpty != rightEmpty { return rightEmpty }          // empties last, both directions
            if !leftEmpty {
                let precedes = sort.ascending
                    ? SortValue.ascendingOrder(left.value, right.value)
                    : SortValue.ascendingOrder(right.value, left.value)
                if let precedes { return precedes }
            }
            return left.index < right.index
        }
        return ordered.map(\.row)
    }
}

/// A column title that sorts its table when clicked. Looks like
/// `InventoryHeaderText`, with an arrow on the column in use.
struct SortableHeaderText<Key: Hashable>: View {
    let title: String
    let key: Key
    @Binding var sort: TableSort<Key>
    /// Type size of the title; tables that draw larger headers pass theirs.
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .semibold

    init(_ title: String, key: Key, sort: Binding<TableSort<Key>>, fontSize: CGFloat = 11, weight: Font.Weight = .semibold) {
        self.title = title
        self.key = key
        self._sort = sort
        self.fontSize = fontSize
        self.weight = weight
    }

    private var isActive: Bool { sort.key == key }

    var body: some View {
        Button {
            sort.toggle(key)
        } label: {
            Text(title)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(isActive ? FleetHubTheme.ink : FleetHubTheme.muted)
                .lineLimit(1)
                // The arrow hangs just past the title instead of sitting in
                // the layout, so a title never moves when its column is
                // chosen and right-aligned titles stay lined up with the
                // values beneath them. Column spacing leaves room for it.
                .overlay(alignment: .trailing) {
                    if isActive {
                        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: max(7, fontSize - 3), weight: .bold))
                            .foregroundStyle(FleetHubTheme.accent)
                            .fixedSize()
                            .alignmentGuide(.trailing) { $0[.leading] - 4 }
                    }
                }
                .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? (sort.ascending ? "Sorted ascending. Click to sort descending." : "Sorted descending. Click to sort ascending.")
                       : "Sort by \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? (sort.ascending ? "Sorted ascending" : "Sorted descending") : "Not sorted")
        .accessibilityHint(isActive ? "Reverses the sort order" : "Sorts the table by this column")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Parses the date strings Jamf returns. Formatters are built once.
enum SortDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()
    private static let fallbacks: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = $0
        return formatter
    }
    private static let lock = NSLock()

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let date = fractional.date(from: trimmed) ?? plain.date(from: trimmed) { return date }
        for formatter in fallbacks {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
