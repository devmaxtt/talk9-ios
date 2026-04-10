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

// MARK: - Errors

/// Errors returned by the Talk9 registration API.
///
/// The server communicates errors via dot-notation i18n keys (e.g. `api.err_otp_wrong`).
/// This enum wraps them and provides a human readable description for the UI.
public enum Talk9APIError: Error, LocalizedError, Equatable {
    case network(String)
    case decoding
    case server(code: String)

    public var errorDescription: String? {
        switch self {
        case .network(let message):
            return message.isEmpty ? "Network error. Please check your connection." : message
        case .decoding:
            return "Unexpected response from the server."
        case .server(let code):
            return Talk9APIError.friendlyMessage(for: code)
        }
    }

    /// Server error key → friendly UI message.
    /// Keys come straight from API.md.
    public static func friendlyMessage(for code: String) -> String {
        switch code {
        case "api.err_username_invalid":
            return "Username is invalid. Use 3–32 lowercase letters, digits, dot, underscore or dash."
        case "api.err_username_required":
            return "Please enter your username."
        case "api.err_no_country_code":
            return "Please select a country code."
        case "api.err_invalid_country_code":
            return "The selected country code is not supported."
        case "api.err_invalid_phone":
            return "Phone number is too short or too long."
        case "api.err_phone_format":
            return "Phone number format is invalid."
        case "api.err_password_too_short":
            return "Password must be at least 8 characters."
        case "api.err_new_password_too_short":
            return "New password must be at least 8 characters."
        case "api.err_password_mismatch":
            return "The two passwords do not match."
        case "api.err_rate_limit_daily":
            return "You have reached the daily OTP limit. Please try again tomorrow."
        case "api.err_rate_limit":
            return "Too many attempts. Please wait and try again."
        case "api.err_otp_send_failed":
            return "Failed to send the OTP. Please try again."
        case "api.err_missing_token":
            return "Session expired. Please restart the flow."
        case "api.err_otp_format":
            return "OTP must be exactly 6 digits."
        case "api.err_token_invalid":
            return "Session is invalid. Please restart the flow."
        case "api.err_otp_expired":
            return "OTP has expired. Please request a new one."
        case "api.err_otp_wrong":
            return "The OTP you entered is incorrect."
        case "api.err_token_expired":
            return "Session expired. Please restart the flow."
        case "api.err_request_failed", "api.err_network":
            return "Request failed. Please try again."
        default:
            // Unknown key — return it as a fallback so the user has a hint.
            return code.isEmpty ? "An unknown error occurred." : code
        }
    }
}

// MARK: - Response payloads

private struct Talk9GenericResponse: Decodable {
    let ok: Bool
    let error: String?
    let token: String?
    let maskedPhone: String?
    let registerToken: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case token
        case maskedPhone = "masked_phone"
        case registerToken = "register_token"
        case displayName = "display_name"
    }
}

/// Result of the Step 1 "send OTP" call (register or reset).
public struct Talk9OTPSession {
    public let token: String
    public let maskedPhone: String
}

// MARK: - Service

/// Networking wrapper around the Talk9 registration / reset password REST API.
/// All calls are plain `POST` requests with a JSON body and return JSON.
public final class Talk9APIService {

    public static let shared = Talk9APIService()

    /// Root of the Talk9 backend. Endpoints defined in API.md are appended to this.
    public var baseURL: URL = URL(string: "https://talk9.co/")!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: Register

    /// Step 1 — Send OTP for the registration flow.
    public func sendOtp(username: String,
                        countryCode: String,
                        phone: String,
                        password: String,
                        password2: String) async throws -> Talk9OTPSession {
        let body: [String: String] = [
            "username": username,
            "country_code": countryCode,
            "phone": phone,
            "password": password,
            "password2": password2
        ]
        let response = try await post(path: "api/send_otp", body: body)
        guard let token = response.token, let masked = response.maskedPhone else {
            throw Talk9APIError.decoding
        }
        return Talk9OTPSession(token: token, maskedPhone: masked)
    }

    /// Step 2 — Verify the OTP; on success returns the short-lived `register_token`.
    public func verifyOtp(token: String, otp: String) async throws -> String {
        let body: [String: String] = ["token": token, "otp": otp]
        let response = try await post(path: "api/verify_otp", body: body)
        guard let registerToken = response.registerToken else {
            throw Talk9APIError.decoding
        }
        return registerToken
    }

    /// Step 2b — Resend OTP for the registration flow.
    public func resendOtp(token: String) async throws -> Talk9OTPSession {
        let body: [String: String] = ["token": token]
        let response = try await post(path: "api/resend_otp", body: body)
        guard let token = response.token, let masked = response.maskedPhone else {
            throw Talk9APIError.decoding
        }
        return Talk9OTPSession(token: token, maskedPhone: masked)
    }

    /// Step 3 — Set display name (optional).
    @discardableResult
    public func setDisplayName(registerToken: String,
                               displayName: String?) async throws -> String? {
        var body: [String: String] = ["register_token": registerToken]
        if let displayName = displayName, !displayName.isEmpty {
            body["display_name"] = displayName
        }
        let response = try await post(path: "api/set_display_name", body: body)
        return response.displayName
    }

    // MARK: Reset Password

    /// Step 1 — Send OTP for the reset password flow.
    public func resetSendOtp(username: String,
                             password: String,
                             password2: String) async throws -> Talk9OTPSession {
        let body: [String: String] = [
            "username": username,
            "password": password,
            "password2": password2
        ]
        let response = try await post(path: "api/reset_send_otp", body: body)
        guard let token = response.token, let masked = response.maskedPhone else {
            throw Talk9APIError.decoding
        }
        return Talk9OTPSession(token: token, maskedPhone: masked)
    }

    /// Step 2 — Verify the reset OTP; on success the password has been updated.
    public func resetVerifyOtp(token: String, otp: String) async throws {
        let body: [String: String] = ["token": token, "otp": otp]
        _ = try await post(path: "api/reset_verify_otp", body: body)
    }

    /// Step 2b — Resend OTP for the reset password flow.
    public func resetResendOtp(token: String) async throws -> Talk9OTPSession {
        let body: [String: String] = ["token": token]
        let response = try await post(path: "api/reset_resend_otp", body: body)
        guard let token = response.token, let masked = response.maskedPhone else {
            throw Talk9APIError.decoding
        }
        return Talk9OTPSession(token: token, maskedPhone: masked)
    }

    // MARK: - Internal

    private func post(path: String, body: [String: String]) async throws -> Talk9GenericResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw Talk9APIError.network("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw Talk9APIError.network("Failed to encode request body")
        }

        // `URLSession.data(for:)` (async) requires iOS 15; bridge the older
        // callback API with a checked continuation so we still support iOS 14.
        let (data, httpResponse) = try await performRequest(request)

        // Try to decode as the standard shape even for 4xx/5xx, since the API
        // returns `{ "ok": false, "error": "..." }` with status 200 for most
        // recoverable errors.
        let decoded: Talk9GenericResponse
        do {
            decoded = try decoder.decode(Talk9GenericResponse.self, from: data)
        } catch {
            if (200..<300).contains(httpResponse.statusCode) {
                throw Talk9APIError.decoding
            }
            throw Talk9APIError.network("Server returned status \(httpResponse.statusCode)")
        }

        if decoded.ok {
            return decoded
        }
        throw Talk9APIError.server(code: decoded.error ?? "api.err_request_failed")
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: Talk9APIError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: Talk9APIError.network("Invalid response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }
}

// MARK: - Country codes

/// Minimal country-code list used by the register form.
/// Keeping it small on purpose — the user asked for "common countries only".
public struct Talk9Country: Identifiable, Hashable {
    public let id: String        // ISO-3166-1 alpha-2, used as Identifiable key
    public let name: String
    public let dialCode: String  // digits only, no `+`
    public let flag: String      // emoji

    public init(id: String, name: String, dialCode: String, flag: String) {
        self.id = id
        self.name = name
        self.dialCode = dialCode
        self.flag = flag
    }
}

public enum Talk9Countries {
    public static let list: [Talk9Country] = [
        Talk9Country(id: "MY", name: "Malaysia",        dialCode: "60",  flag: "🇲🇾"),
        Talk9Country(id: "SG", name: "Singapore",       dialCode: "65",  flag: "🇸🇬"),
        Talk9Country(id: "CN", name: "China",           dialCode: "86",  flag: "🇨🇳"),
        Talk9Country(id: "HK", name: "Hong Kong",       dialCode: "852", flag: "🇭🇰"),
        Talk9Country(id: "TW", name: "Taiwan",          dialCode: "886", flag: "🇹🇼"),
        Talk9Country(id: "ID", name: "Indonesia",       dialCode: "62",  flag: "🇮🇩"),
        Talk9Country(id: "TH", name: "Thailand",        dialCode: "66",  flag: "🇹🇭"),
        Talk9Country(id: "PH", name: "Philippines",     dialCode: "63",  flag: "🇵🇭"),
        Talk9Country(id: "VN", name: "Vietnam",         dialCode: "84",  flag: "🇻🇳"),
        Talk9Country(id: "IN", name: "India",           dialCode: "91",  flag: "🇮🇳"),
        Talk9Country(id: "JP", name: "Japan",           dialCode: "81",  flag: "🇯🇵"),
        Talk9Country(id: "KR", name: "South Korea",     dialCode: "82",  flag: "🇰🇷"),
        Talk9Country(id: "AU", name: "Australia",       dialCode: "61",  flag: "🇦🇺"),
        Talk9Country(id: "GB", name: "United Kingdom",  dialCode: "44",  flag: "🇬🇧"),
        Talk9Country(id: "US", name: "United States",   dialCode: "1",   flag: "🇺🇸")
    ]

    public static let `default`: Talk9Country = list.first! // Malaysia
}
