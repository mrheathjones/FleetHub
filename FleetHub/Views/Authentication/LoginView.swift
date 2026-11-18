//
//  LoginView.swift
//  FleetHub
//
//  Sign-in: the right half of the two-panel sign-in card. Microsoft Entra
//  when the profile selects it (fail-closed when it is misconfigured),
//  otherwise the email form.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel
    @Binding var showLogin: Bool

    @Environment(\.openURL) private var openURL

    @State private var email = ""
    @FocusState private var emailFieldFocused: Bool

    var body: some View {
        SignInPanel {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.hasSeenWelcome ? "Welcome Back" : "Sign In")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = viewModel.errorMessage {
                SignInNotice(text: errorMessage) {
                    withAnimation { viewModel.errorMessage = nil }
                }
                .transition(.opacity)
            }

            if viewModel.signInMethod == .entra {
                if viewModel.isEntraSignInConfigured {
                    SSOButton(
                        icon: "person.badge.key.fill",
                        title: viewModel.isLoading ? "Waiting for Microsoft Sign-In…" : "Sign In with Microsoft",
                        isBusy: viewModel.isLoading
                    ) {
                        viewModel.loginWithEntra()
                    }
                    .disabled(viewModel.isLoading)
                } else {
                    // FAIL-CLOSED: entra selected but unusable — show the
                    // configuration error, never the weaker email form.
                    configurationError
                }
            } else {
                emailField
                SSOButton(
                    icon: "arrow.right",
                    title: viewModel.isLoading ? "Authenticating…" : "Continue",
                    isBusy: viewModel.isLoading
                ) {
                    login()
                }
                .disabled(viewModel.isLoading || !isValidEmail(email))
                .opacity(isValidEmail(email) || viewModel.isLoading ? 1 : 0.5)
            }

            biometricNote
            helpLine

            Spacer(minLength: 0)
        }
        .onAppear {
            if viewModel.signInMethod == .email {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    emailFieldFocused = true
                }
            }
        }
    }

    private var subtitle: String {
        viewModel.signInMethod == .entra
            ? "You'll sign in through your organization's Microsoft account."
            : "Enter your work email. We'll retrieve or create your secure API credentials."
    }

    // MARK: - Email

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email Address")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)

            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .foregroundStyle(FleetHubTheme.muted)

                // Verbatim: as a localized key the address is parsed as
                // Markdown and auto-linked, which tints it like a real value.
                ZStack(alignment: .leading) {
                    if email.isEmpty {
                        Text(verbatim: "you@example.com")
                            .font(.system(size: 15))
                            .foregroundStyle(FleetHubTheme.muted)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $email)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(FleetHubTheme.ink)
                        .disableAutocorrection(true)
                        .focused($emailFieldFocused)
                        .onSubmit { login() }
                        .accessibilityLabel("Email Address")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(emailFieldFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Configuration error

    /// Entra mode with missing tenant/client id: fail-closed dead end —
    /// there is deliberately no email fallback here.
    private var configurationError: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(FleetHubTheme.warnText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign-In Is Not Configured on This Mac")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Contact your administrator.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.warnFill))
    }

    // MARK: - Biometric note

    /// Only where the Mac has biometric hardware and policy allows setting
    /// it up — otherwise the promise would be false.
    @ViewBuilder
    private var biometricNote: some View {
        let type = viewModel.biometricManager.biometricType
        if type != .none, viewModel.isBiometricSetupAllowed {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(FleetHubTheme.control)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(FleetHubTheme.surface)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(type.displayName) Unlock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text("After your first sign-in you can unlock \(Branding.productName) with \(type.displayName).")
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.ground))
        }
    }

    // MARK: - Help

    /// Shown only when the ui domain delivers a supportURL — the schema
    /// contract is "leave empty to hide", so there is no placeholder
    /// fallback.
    @ViewBuilder
    private var helpLine: some View {
        if let url = Branding.supportURL {
            HStack(spacing: 4) {
                Text("Need help?")
                    .foregroundStyle(FleetHubTheme.muted)
                Button {
                    openURL(url)
                } label: {
                    Text("Contact Support")
                        .fontWeight(.semibold)
                        .foregroundStyle(FleetHubTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
        }
    }

    // MARK: - Actions

    private func login() {
        guard isValidEmail(email) else { return }
        viewModel.loginWithEmail(email)
    }

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Login View") {
    @Previewable @State var showLogin = true
    LoginView(viewModel: AuthViewModel(), showLogin: $showLogin)
        .frame(width: 1100, height: 800)
}
#endif
