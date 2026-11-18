//
//  DeviceSection.swift
//  FleetHub
//
//  Sidebar sections of the computer detail view.
//

import Foundation

enum DeviceSection: String, CaseIterable {
    case overview
    case hardware
    case storage
    case security
    case operatingSystem
    case userAndLocation
    case applications
    case profiles
    case localAccounts
    case diskEncryption
    case certificates
    /// Jamf Compliance Benchmarks result (Platform API; hidden when no
    /// Platform integration is configured).
    case compliance
    case printers
    case purchasing
    case groupMemberships
    case extensionAttributes
    case management
    /// DDM enabled state and reported status items.
    case declarativeManagement
    case logs
    case history

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hardware: return "Hardware"
        case .storage: return "Storage"
        case .security: return "Security"
        case .operatingSystem: return "Operating System"
        case .userAndLocation: return "User & Location"
        case .applications: return "Applications"
        case .profiles: return "Profiles"
        case .localAccounts: return "Local Accounts"
        case .diskEncryption: return "Disk Encryption"
        case .certificates: return "Certificates"
        case .compliance: return "Compliance"
        case .printers: return "Printers"
        case .purchasing: return "Purchasing"
        case .groupMemberships: return "Groups"
        case .extensionAttributes: return "Extension Attributes"
        case .management: return "Management"
        case .declarativeManagement: return "Declarative Management"
        case .logs: return "Action Logs"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .hardware: return "cpu"
        case .storage: return "internaldrive"
        case .security: return "shield.checkered"
        case .operatingSystem: return "apple.logo"
        case .userAndLocation: return "person.fill"
        case .applications: return "app.badge"
        case .profiles: return "doc.badge.gearshape"
        case .localAccounts: return "person.2"
        case .diskEncryption: return "lock.doc"
        case .certificates: return "checkmark.seal"
        case .compliance: return "checklist"
        case .printers: return "printer"
        case .purchasing: return "dollarsign.circle"
        case .groupMemberships: return "person.3"
        case .extensionAttributes: return "list.bullet.rectangle"
        case .management: return "gearshape.2"
        case .declarativeManagement: return "list.bullet.clipboard"
        case .logs: return "doc.text.magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Section Groups

/// The six tabs the computer detail view groups its sections under. Every
/// `DeviceSection` belongs to exactly one group; the order here is the order
/// of the tabs, and each group's `sections` order is the order of its chips.
enum DeviceSectionGroup: String, CaseIterable, Identifiable {
    case overview
    case hardware
    case security
    case software
    case management
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hardware: return "Hardware"
        case .security: return "Security"
        case .software: return "Software"
        case .management: return "Management"
        case .activity: return "Activity"
        }
    }

    var sections: [DeviceSection] {
        switch self {
        case .overview: return [.overview]
        case .hardware: return [.hardware, .storage, .printers, .purchasing]
        case .security: return [.security, .compliance, .diskEncryption, .certificates, .localAccounts]
        case .software: return [.operatingSystem, .applications, .profiles]
        case .management: return [.userAndLocation, .groupMemberships, .extensionAttributes, .management, .declarativeManagement]
        case .activity: return [.logs, .history]
        }
    }

    static func group(for section: DeviceSection) -> DeviceSectionGroup {
        allCases.first { $0.sections.contains(section) } ?? .overview
    }
}
