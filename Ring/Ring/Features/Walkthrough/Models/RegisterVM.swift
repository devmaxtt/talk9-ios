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

/// Steps of the Talk9 register flow as described in API.md.
public enum RegisterStep {
    case credentials   // Step 1 — username / phone / password
    case otp           // Step 2 — verify OTP
    case displayName   // Step 3 — optional display name
    case done          // Flow finished
}

/// Drives the three-step Talk9 register flow.
/// Uses `Task { } + DispatchQueue.main.async { [weak self] in }` for all
/// async work, matching the project's existing VM style (see WelcomeVM).
final class RegisterVM: ObservableObject {

    // MARK: UI state (must only be written on main thread)

    @Published var step: RegisterStep = .credentials
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Step 1 fields
    @Published var username: String = ""
    @Published var country: Talk9Country = Talk9Countries.default
    @Published var phone: String = ""
    @Published var password: String = ""
    @Published var passwordConfirm: String = ""

    // Step 2 fields
    @Published var otp: String = ""
    @Published var maskedPhone: String = ""

    // Step 3 fields
    @Published var displayName: String = ""

    // Tokens returned by the server — only accessed from main thread via closures
    private var otpToken: String?
    private var registerToken: String?

    private let api: Talk9APIService

    init(api: Talk9APIService = .shared) {
        self.api = api
    }

    // MARK: - Step 1 — Send OTP

    /// Basic client-side validation before hitting the network.
    private func validateCredentials() -> String? {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "Please enter a username." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        if u.count < 3 || u.count > 32 || !u.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return Talk9APIError.friendlyMessage(for: "api.err_username_invalid")
        }
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || !p.allSatisfy({ $0.isNumber }) {
            return Talk9APIError.friendlyMessage(for: "api.err_invalid_phone")
        }
        if password.count < 8 {
            return Talk9APIError.friendlyMessage(for: "api.err_password_too_short")
        }
        if password != passwordConfirm {
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
        let dialCode = country.dialCode
        let phone = phone.trimmingCharacters(in: .whitespaces)
        let password = password
        let password2 = passwordConfirm
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let session = try await self.api.sendOtp(
                    username: username,
                    countryCode: dialCode,
                    phone: phone,
                    password: password,
                    password2: password2
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.otpToken = session.token
                    self.maskedPhone = session.maskedPhone
                    self.otp = ""
                    self.isLoading = false
                    self.step = .otp
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    // MARK: - Step 2 — Verify / Resend OTP

    func verifyOtp() {
        let currentOtp = otp
        guard let token = otpToken else {
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
                let regToken = try await self.api.verifyOtp(token: token, otp: currentOtp)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.registerToken = regToken
                    self.isLoading = false
                    self.step = .displayName
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    func resendOtp() {
        guard let token = otpToken else {
            errorMessage = Talk9APIError.friendlyMessage(for: "api.err_missing_token")
            return
        }
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let session = try await self.api.resendOtp(token: token)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.otpToken = session.token
                    self.maskedPhone = session.maskedPhone
                    self.otp = ""
                    self.isLoading = false
                }
            } catch {
                self.handleError(error)
            }
        }
    }

    // MARK: - Step 3 — Set display name

    func submitDisplayName() {
        guard let token = registerToken else {
            errorMessage = Talk9APIError.friendlyMessage(for: "api.err_missing_token")
            return
        }
        let name: String? = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedUsername = username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPhone = "+\(country.dialCode)\(phone.trimmingCharacters(in: .whitespaces))"
        setLoading(true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await self.api.setDisplayName(registerToken: token, displayName: name)
                UserDefaults.standard.set(savedPhone,
                                          forKey: Constants.talk9RegisteredPhonePrefix + savedUsername)
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

    func skipDisplayName() {
        displayName = ""
        submitDisplayName()
    }

    // MARK: - Helpers

    /// Convenience — always called from the main thread (button actions in SwiftUI views).
    private func setLoading(_ loading: Bool) {
        errorMessage = nil
        isLoading = loading
    }

    /// Called from a `Task` closure (background); dispatches error back to main.
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
