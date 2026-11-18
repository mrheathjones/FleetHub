//
//  BiometricPromptView.swift
//  FleetHub
//
//  Returning-user unlock: the right half of the two-panel sign-in card,
//  asking for Touch ID / Face ID instead of a full sign-in.
//

import SwiftUI

struct BiometricPromptView: View {
    @ObservedObject var viewModel: AuthViewModel
    /// False only for the DEBUG layout preview.
    var autoPrompt = true

    private var type: BiometricAuthManager.BiometricType { viewModel.biometricManager.biometricType }

    var body: some View {
        SignInPanel {
            Spacer(minLength: 0)

            Image(systemName: type.icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FleetHubTheme.accent)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(FleetHubTheme.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome Back")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Unlock \(Branding.productName) with \(type.displayName).")
                    .font(.system(size: 14))
                    .foregroundStyle(FleetHubTheme.muted)
            }

            if let errorMessage = viewModel.errorMessage {
                SignInNotice(text: errorMessage)
                    .transition(.opacity)
            }

            VStack(spacing: 8) {
                SSOButton(icon: type.icon, title: "Unlock") {
                    viewModel.authenticateWithBiometrics()
                }
                SSOButton(title: "Sign In a Different Way", kind: .secondary) {
                    withAnimation {
                        viewModel.showBiometricPrompt = false
                        viewModel.currentUser = nil
                        viewModel.clearSession()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            guard autoPrompt else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.authenticateWithBiometrics()
            }
        }
    }
}
