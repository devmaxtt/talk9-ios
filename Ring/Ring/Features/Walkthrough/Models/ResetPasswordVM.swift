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

import Foundation
import SwiftUI

/// Steps of the Talk9 reset-password flow as described in API.md.
public enum ResetPasswordStep {
    case credentials   // Step 1 — username + new password
    case otp           // Step 2 — verify OTP
    case done          // Flow finished
}

/// Drives the two-step Talk9 reset-password flow.
/// Uses `Task { } + DispatchQueue.main.async { [weak self] in }` for all
/// async work, matching the project's existing VM style (see WelcomeVM).
final class ResetPasswordVM: ObservableObject {

    // MARK: UI state (must only be written on main thread)

    @Published var step: ResetPasswordStep = .credentials
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Step 1 fields
    @Published var username: String = ""
    @Published var newPassword: String = ""
    @Published var newPasswordConfirm: String = ""

    // Step 2 fields
    @Published var otp: String = ""
    @Published var maskedPhone: String = ""

    /// `true` when the server returned a real phone; `false` when `masked_phone == "***"`.
    /// The view shows an anti-enumeration neutral message when `false`.
    @Published var userExists: Bool = true

    private var resetToken: String?

    private let api: Talk9APIService

    init(api: Talk9APIService = .shared) {
        self.api = api
    }

    // MARK: - Step 1 — Send OTP

    private func validateCredentials() -> String? {
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Talk9APIError.friendlyMessage(for: "api.err_username_required")
        }
        if newPassword.count < 8 {
            return Talk9APIError.friendlyMessage(for: "api.err_new_password_too_short")
        }
        if newPassword != newPasswordConfirm {
            return Talk9APIError.friendlyMessage(for: "api.err_password_mismatch")
        }
        return nil
    }

    func sendOtp() {
        if let message = validateCredentials() {
            errorMessage = message
            return
        }
        let username = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let password = newPassword
        let password2 = newPasswordConfirm
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let session = try await self.api.resetSendOtp(
                    username: username,
                    password: password,
                    password2: password2
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.resetToken = session.token
                    self.maskedPhone = session.maskedPhone
                    self.userExists = (session.maskedPhone != "***")
                    self.otp = ""
                    self.isLoading = false
                    self.step = .otp
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    // MARK: - Step 2 — Verify / Resend

    func verifyOtp() {
        let currentOtp = otp
        guard let token = resetToken else {
            errorMessage = Talk9APIError.friendlyMessage(for: "api.err_missing_token")
            return
        }
        if currentOtp.count != 6 || !currentOtp.allSatisfy({ $0.isNumber }) {
            errorMessage = Talk9APIError.friendlyMessage(for: "api.err_otp_format")
            return
        }
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.api.resetVerifyOtp(token: token, otp: currentOtp)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isLoading = false
                    self.step = .done
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    func resendOtp() {
        guard let token = resetToken else {
            errorMessage = Talk9APIError.friendlyMessage(for: "api.err_missing_token")
            return
        }
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let session = try await self.api.resetResendOtp(token: token)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.resetToken = session.token
                    self.maskedPhone = session.maskedPhone
                    self.userExists = (session.maskedPhone != "***")
                    self.otp = ""
                    self.isLoading = false
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    // MARK: - Helpers

    private func setLoading(_ loading: Bool) {
        errorMessage = nil
        isLoading = loading
    }

    private func handleError(_ error: Error) {
        let message: String
        if let apiError = error as? Talk9APIError {
            message = apiError.errorDescription ?? error.localizedDescription
        } else {
            message = error.localizedDescription
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.errorMessage = message
            self.isLoading = false
        }
    }
}
