//
//  BiometricSetupPromptView.swift
//  FleetHub
//
//  One-time offer, after the first sign-in, to unlock with biometrics.
//

import SwiftUI

struct BiometricSetupPromptView: View {
    @ObservedObject var viewModel: AuthViewModel
    @Binding var isPresented: Bool

    private var name: String { viewModel.biometricManager.biometricType.displayName }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 20) {
                Image(systemName: viewModel.biometricManager.biometricType.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(FleetHubTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(FleetHubTheme.accent.opacity(0.12))
                    )

                VStack(spacing: 6) {
                    Text("Enable \(name)?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)

                    Text("Use \(name) to unlock \(Branding.productName) quickly and securely.")
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    SSOButton(icon: viewModel.biometricManager.biometricType.icon, title: "Enable \(name)") {
                        viewModel.enableBiometricAuth()
                        isPresented = false
                    }
                    SSOButton(title: "Not Now", kind: .secondary) {
                        isPresented = false
                    }
                }
            }
            .padding(28)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
    }
}
