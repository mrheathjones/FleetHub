//
//  AppLog.swift
//  FleetHub
//
//  The app's diagnostic log. It writes to the unified log (Console.app,
//  `log show`, sysdiagnose) through `Logger`, with one rule:
//
//  The fixed words of a message are public. Every value put into it is
//  private unless it is a number or a Boolean, or the call says
//  `privacy: .public`. So device names, serial numbers, usernames, email
//  addresses, identifiers, addresses and error text never appear in the
//  log in readable form.
//
//      AppLog.notice("Sending Erase command to \(computer.displayName)")
//
//  is recorded as
//
//      Sending Erase command to ‹…› [<private>]
//
//  The bracketed part is the whole message, held as private data. macOS
//  shows it only while a debugger is attached, or on a Mac whose logging
//  configuration enables private data for this subsystem, so a full
//  message can still be had for a support case without being on by default.
//  DEBUG builds write the whole message in the clear.
//

import Foundation
import os

/// Whether an interpolated value may appear in the log in readable form.
enum AppLogPrivacy {
    case `public`
    case `private`
}

/// A log message: fixed text plus values, each public or private.
struct AppLogMessage: ExpressibleByStringInterpolation {
    /// The message with every private value replaced by a marker.
    let redacted: String
    /// The message in full.
    let full: String
    /// True when at least one value was replaced.
    let hasPrivateValues: Bool

    init(stringLiteral value: String) {
        redacted = value
        full = value
        hasPrivateValues = false
    }

    init(stringInterpolation: StringInterpolation) {
        redacted = stringInterpolation.redacted
        full = stringInterpolation.full
        hasPrivateValues = stringInterpolation.hasPrivateValues
    }

    private init(redacted: String, full: String, hasPrivateValues: Bool) {
        self.redacted = redacted
        self.full = full
        self.hasPrivateValues = hasPrivateValues
    }

    /// The same message with fixed text in front.
    func prefixed(_ prefix: String) -> AppLogMessage {
        AppLogMessage(redacted: prefix + redacted, full: prefix + full, hasPrivateValues: hasPrivateValues)
    }

    struct StringInterpolation: StringInterpolationProtocol {
        static let marker = "‹…›"

        var redacted = ""
        var full = ""
        var hasPrivateValues = false

        init(literalCapacity: Int, interpolationCount: Int) {
            redacted.reserveCapacity(literalCapacity + interpolationCount * 3)
            full.reserveCapacity(literalCapacity + interpolationCount * 12)
        }

        mutating func appendLiteral(_ literal: String) {
            redacted += literal
            full += literal
        }

        private mutating func append(_ text: String, privacy: AppLogPrivacy) {
            full += text
            switch privacy {
            case .public:
                redacted += text
            case .private:
                redacted += Self.marker
                hasPrivateValues = true
            }
        }

        /// Any value: private unless stated otherwise.
        mutating func appendInterpolation<T>(_ value: T, privacy: AppLogPrivacy = .private) {
            append(String(describing: value), privacy: privacy)
        }

        // Numbers and Booleans say nothing about a person or a device on
        // their own (counts, status codes, durations), so they are public.
        mutating func appendInterpolation(_ value: Int) { append(String(value), privacy: .public) }
        mutating func appendInterpolation(_ value: Int32) { append(String(value), privacy: .public) }
        mutating func appendInterpolation(_ value: Int64) { append(String(value), privacy: .public) }
        mutating func appendInterpolation(_ value: UInt) { append(String(value), privacy: .public) }
        mutating func appendInterpolation(_ value: Double) { append(String(value), privacy: .public) }
        mutating func appendInterpolation(_ value: Bool) { append(String(value), privacy: .public) }
    }
}

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub"

    /// Something worth having in the log.
    static func notice(_ message: AppLogMessage, file: String = #fileID) {
        write(message, type: .default, file: file)
    }

    /// Something that went wrong.
    static func error(_ message: AppLogMessage, file: String = #fileID) {
        write(message, type: .error, file: file)
    }

    private static func write(_ message: AppLogMessage, type: OSLogType, file: String) {
        // The source file's name is the category: "FleetHub/AbmAPIService.swift" → "AbmAPIService".
        let name = file.split(separator: "/").last.map(String.init) ?? file
        let category = name.hasSuffix(".swift") ? String(name.dropLast(6)) : name
        let logger = Logger(subsystem: subsystem, category: category)
        #if DEBUG
        logger.log(level: type, "\(message.full, privacy: .public)")
        #else
        if message.hasPrivateValues {
            logger.log(level: type, "\(message.redacted, privacy: .public) [\(message.full, privacy: .private)]")
        } else {
            logger.log(level: type, "\(message.redacted, privacy: .public)")
        }
        #endif
    }
}
