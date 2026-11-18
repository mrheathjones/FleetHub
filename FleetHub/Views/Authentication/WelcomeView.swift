//
//  WelcomeView.swift
//  FleetHub
//
//  First launch. The welcome copy now lives on the sign-in card's brand
//  panel, so a first-time visitor lands straight on sign-in; the only
//  difference from a returning one is the greeting.
//

import SwiftUI

struct WelcomeView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        LoginView(viewModel: viewModel, showLogin: .constant(true))
    }
}
