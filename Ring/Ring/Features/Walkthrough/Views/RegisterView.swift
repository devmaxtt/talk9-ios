/*
 *  Copyright (C) 2026 Savoir-faire Linux Inc.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA.
 */

import SwiftUI

/// Three-step Talk9 register flow:
/// 1. Enter username / phone / password → request OTP
/// 2. Enter 6-digit OTP → verify
/// 3. Optional display name → done
struct RegisterView: View {

    @StateObject var viewModel: RegisterVM
    let dismissHandler = DismissHandler()

    init(viewModel: RegisterVM = RegisterVM()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        switch viewModel.step {
                        case .credentials:
                            credentialsStep
                        case .otp:
                            otpStep
                        case .displayName:
                            displayNameStep
                        case .done:
                            doneStep
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }

            if viewModel.isLoading {
                loadingOverlay
            }
        }
        .applyJamiBackground()
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("Error"),
                message: Text(viewModel.errorMessage ?? ""),
                dismissButton: .default(Text("OK")) {
                    viewModel.errorMessage = nil
                }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { handleBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(10)
                }
                Spacer()
                Text("Register")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                // Invisible spacer to keep the title centred.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            progressIndicator
                .padding(.horizontal, 24)
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            progressDot(active: viewModel.step == .credentials)
            progressDot(active: viewModel.step == .otp)
            progressDot(active: viewModel.step == .displayName || viewModel.step == .done)
        }
        .padding(.bottom, 8)
    }

    private func progressDot(active: Bool) -> some View {
        Capsule()
            .fill(active ? Color.blue : Color.white.opacity(0.3))
            .frame(height: 4)
    }

    // MARK: Step 1 — Credentials

    private var credentialsStep: some View {
        VStack(spacing: 14) {
            Text("Create your Talk9 account")
                .font(.title3.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            labeledField(icon: "person") {
                WalkthroughTextEditView(
                    text: $viewModel.username,
                    placeholder: "Username",
                    backgroundColor: .clear
                )
            }

            HStack(spacing: 10) {
                countryMenu
                labeledField(icon: "phone", leadingSpacing: 8) {
                    TextField("Phone number", text: $viewModel.phone)
                        .keyboardType(.numberPad)
                        .foregroundColor(Color(UIColor.label))
                        .padding(.vertical, 12)
                }
            }

            labeledField(icon: "lock") {
                WalkthroughPasswordView(
                    text: $viewModel.password,
                    placeholder: "Password (min 8 chars)",
                    backgroundColor: .clear
                )
            }

            labeledField(icon: "lock.rotation") {
                WalkthroughPasswordView(
                    text: $viewModel.passwordConfirm,
                    placeholder: "Confirm password",
                    backgroundColor: .clear
                )
            }

            primaryButton(title: "Send OTP") {
                viewModel.sendOtp()
            }
            .padding(.top, 4)

            Text("We will send a 6-digit code to your phone to verify your number.")
                .font(.footnote)
                .foregroundColor(Color.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var countryMenu: some View {
        Menu {
            ForEach(Talk9Countries.list) { country in
                Button {
                    viewModel.country = country
                } label: {
                    Text("\(country.flag)  \(country.name)  +\(country.dialCode)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.country.flag)
                Text("+\(viewModel.country.dialCode)")
                    .foregroundColor(Color(UIColor.label))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundColor(Color(UIColor.secondaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    // MARK: Step 2 — OTP

    private var otpStep: some View {
        VStack(spacing: 14) {
            Text("Enter verification code")
                .font(.title3.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("We sent a 6-digit code to \(viewModel.maskedPhone).")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)

            labeledField(icon: "number") {
                TextField("6-digit OTP", text: $viewModel.otp)
                    .keyboardType(.numberPad)
                    .foregroundColor(Color(UIColor.label))
                    .padding(.vertical, 12)
                    .onChange(of: viewModel.otp) { newValue in
                        // Cap at 6 digits.
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue || filtered.count > 6 {
                            viewModel.otp = String(filtered.prefix(6))
                        }
                    }
            }

            primaryButton(title: "Verify") {
                viewModel.verifyOtp()
            }
            .padding(.top, 4)

            Button {
                viewModel.resendOtp()
            } label: {
                Text("Resend code")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: Step 3 — Display name

    private var displayNameStep: some View {
        VStack(spacing: 14) {
            Text("Set a display name")
                .font(.title3.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("This is how other people will see you. You can skip this step and use your username instead.")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)

            labeledField(icon: "textformat") {
                WalkthroughTextEditView(
                    text: $viewModel.displayName,
                    placeholder: "Display name (optional)",
                    backgroundColor: .clear
                )
            }

            primaryButton(title: "Continue") {
                viewModel.submitDisplayName()
            }
            .padding(.top, 4)

            Button {
                viewModel.skipDisplayName()
            } label: {
                Text("Skip for now")
                    .font(.subheadline)
                    .foregroundColor(Color.white.opacity(0.85))
            }
        }
    }

    // MARK: Final — Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.green)
                .padding(.top, 24)

            Text("Account created")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("You can now sign in with your username and password.")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            primaryButton(title: "Back to sign in") {
                dismissHandler.dismissView()
            }
            .padding(.top, 8)
        }
    }

    // MARK: Shared UI

    private func labeledField<Content: View>(
        icon: String,
        leadingSpacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: leadingSpacing) {
            Image(systemName: icon)
                .foregroundColor(Color(UIColor.secondaryLabel))
                .frame(width: 18)
            content()
        }
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.jamiButtonDark))
                .foregroundColor(.white)
                .cornerRadius(12)
        }
        .disabled(viewModel.isLoading)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            SwiftUI.ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.3)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func handleBack() {
        switch viewModel.step {
        case .credentials, .done:
            dismissHandler.dismissView()
        case .otp:
            viewModel.step = .credentials
        case .displayName:
            // Once we've created the LDAP account there is no going back to
            // the OTP step, but the user can dismiss the flow if they like.
            dismissHandler.dismissView()
        }
    }
}
