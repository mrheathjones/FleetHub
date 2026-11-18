//
//  PlaceholderViews.swift
//  FleetHub
//
//  Placeholder views for sidebar navigation destinations
//

import SwiftUI

// MARK: - Devices View

struct DevicesView: View {
    @Binding var isInNestedView: Bool
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            DeviceListView(platform: .all, navigationPath: $navigationPath)
                .navigationDestination(for: Computer.self) { computer in
                    DeviceView(computer: computer)
                }
                .navigationDestination(for: MobileDevice.self) { device in
                    MobileDeviceView(device: device)
                }
        }
        .onChange(of: navigationPath.count) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = newValue > 0
            }
        }
        .onAppear {
            isInNestedView = false
            consumeDeepLinkIfPresent()
        }
        .onChange(of: deepLinkRouter.pendingRequest) { oldValue, newValue in
            if newValue != nil {
                consumeDeepLinkIfPresent()
            }
        }
    }
    
    /// Check the router for a pending request, consume it, and push the device.
    private func consumeDeepLinkIfPresent() {
        guard let request = deepLinkRouter.pendingRequest else { return }
        
        AppLog.notice("🔗 DevicesView: Consuming deep link — type: \(request.deviceType.rawValue), id: \(request.deviceID)")
        
        // Clear immediately so it doesn't re-fire
        deepLinkRouter.clearRequest()
        
        // Push the device onto the nav stack after a brief delay to let the view settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            switch request.deviceType {
            case .computer:
                let json = """
                {"id":"\(request.deviceID)","udid":""}
                """.data(using: .utf8)!
                if let stub = try? JSONDecoder().decode(Computer.self, from: json) {
                    navigationPath.append(stub)
                }
            case .mobiledevice:
                let json = """
                {"id":"\(request.deviceID)"}
                """.data(using: .utf8)!
                if let stub = try? JSONDecoder().decode(MobileDevice.self, from: json) {
                    navigationPath.append(stub)
                }
            }
        }
    }
}

// MARK: - Announcements View

// NOTE: AnnouncementsView has been moved to Views/Announcements/AnnouncementsView.swift

// MARK: - Reports View

// NOTE: ReportsView has been moved to Views/Reports/ReportsView.swift

// NOTE: EnrollmentsView has been moved to Views/Enrollments/EnrollmentsView.swift

// NOTE: SettingsView has been moved to Views/Settings/SettingsView.swift

// MARK: - Previews

#if DEBUG
#Preview("Devices View") {
    @Previewable @State var isNested = false
    DevicesView(isInNestedView: $isNested)
        .environmentObject(DeepLinkRouter())
        .frame(width: 1200, height: 800)
}

#Preview("Settings View") {
    SettingsView()
        .frame(width: 1200, height: 800)
}
#endif
