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

/// Two-step Talk9 reset-password flow:
/// 1. Enter username + new password → request OTP
/// 2. Enter 6-digit OTP → verify → done
struct ResetPasswordView: View {

    @StateObject var viewModel: ResetPasswordVM
    let dismissHandler = DismissHandler()

    init(viewModel: ResetPasswordVM = ResetPasswordVM()) {
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
                Text("Reset password")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
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
            progressDot(active: viewModel.step == .otp || viewModel.step == .done)
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
            Text("Forgot your password?")
                .font(.title3.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Enter your username and a new password. We will send an OTP to the phone number on file to confirm.")
                .font(.subheadline)
                .foregroundColor(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)

            labeledField(icon: "person") {
                WalkthroughTextEditView(
                    text: $viewModel.username,
                    placeholder: "Username",
                    backgroundColor: .clear
                )
            }

            labeledField(icon: "lock") {
                WalkthroughPasswordView(
                    text: $viewModel.newPassword,
                    placeholder: "New password (min 8 chars)",
                    backgroundColor: .clear
                )
            }

            labeledField(icon: "lock.rotation") {
                WalkthroughPasswordView(
                    text: $viewModel.newPasswordConfirm,
                    placeholder: "Confirm new password",
                    backgroundColor: .clear
                )
            }

            primaryButton(title: "Send OTP") {
                viewModel.sendOtp()
            }
            .padding(.top, 4)
        }
    }

    // MARK: Step 2 — OTP

    private var otpStep: some View {
        VStack(spacing: 14) {
            Text("Enter verification code")
                .font(.title3.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if viewModel.userExists {
                    Text("We sent a 6-digit code to \(viewModel.maskedPhone).")
                } else {
                    // Anti-enumeration message per API.md.
                    Text("If that username is registered, a code will be sent to the phone number on file.")
                }
            }
            .font(.subheadline)
            .foregroundColor(Color.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)

            labeledField(icon: "number") {
                TextField("6-digit OTP", text: $viewModel.otp)
                    .keyboardType(.numberPad)
                    .foregroundColor(Color(UIColor.label))
                    .padding(.vertical, 12)
                    .onChange(of: viewModel.otp) { newValue in
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

    // MARK: Final — Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.green)
                .padding(.top, 24)

            Text("Password updated")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("You can now sign in with your new password.")
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
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
        }
    }
}
