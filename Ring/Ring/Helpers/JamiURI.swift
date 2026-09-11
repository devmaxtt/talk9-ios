/*
 *  Copyright (C) 2019 - 2025 Savoir-faire Linux Inc.
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

enum URIType {
    case jami
    case ring
    case sip
    case unrecognized

    func getString() -> String {
        switch self {
        case .jami:
            return "jami"
        case .ring:
            return "ring"
        case .sip:
            return "sip"
        case .unrecognized:
            return ""
        }
    }

    var isJamiType: Bool {
        return self == .jami || self == .ring
    }

    init(from scheme: String?) {
        guard let scheme = scheme?.lowercased().replacingOccurrences(of: ":", with: "") else {
            self = .unrecognized
            return
        }
        switch scheme {
        case "jami": self = .jami
        case "ring": self = .ring
        case "sip": self = .sip
        default: self = .unrecognized
        }
    }
}

class JamiURI {
    private static let uriPattern = try? NSRegularExpression(
        pattern: "^\\s*(\\w+:)?(?:([\\w.]+)@)?([\\d\\w.\\-]+)?(?::(\\d+))?\\s*$",
        options: .caseInsensitive
    )
    private static let hexIdPattern = try? NSRegularExpression(
        pattern: "^[0-9a-fA-F]{40}$",
        options: .caseInsensitive
    )

    var schema: URIType
    var userInfo: String = ""
    var hostname: String = ""
    var port: String = ""

    // MARK: - Initializers

    init(schema: URIType) {
        self.schema = schema
    }

    init(schema: URIType, infoHash: String, account: AccountModel) {
        let parsed = JamiURI(from: infoHash)
        self.schema = schema
        self.userInfo = parsed.userInfo
        self.hostname = parsed.hostname
        self.port = parsed.port
        if schema == .sip {
            if self.hostname.isEmpty {
                self.hostname = account.details?.get(withConfigKeyModel: ConfigKeyModel(withKey: ConfigKey.accountHostname)) ?? ""
            }
            if self.port.isEmpty {
                self.port = account.details?.get(withConfigKeyModel: ConfigKeyModel(withKey: ConfigKey.localPort)) ?? ""
            }
        }
    }

    init(schema: URIType, infoHash: String) {
        let parsed = JamiURI(from: infoHash)
        self.schema = schema
        self.userInfo = parsed.userInfo
        self.hostname = parsed.hostname
        self.port = parsed.port
    }

    init(from uriString: String) {
        let normalizedUri = uriString
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "@ring.dht", with: "")
            .trimmingCharacters(in: .whitespaces)

        let range = NSRange(location: 0, length: normalizedUri.utf16.count)

        if let match = JamiURI.uriPattern?.firstMatch(in: normalizedUri, options: [], range: range) {
            let scheme = JamiURI.group(match, 1, in: normalizedUri)
            let user = JamiURI.group(match, 2, in: normalizedUri)
            let host = JamiURI.group(match, 3, in: normalizedUri)
            let port = JamiURI.group(match, 4, in: normalizedUri)

            self.schema = URIType(from: scheme)
            self.userInfo = user ?? ""
            self.hostname = host ?? ""
            self.port = port ?? ""

            if self.schema.isJamiType && self.userInfo.isEmpty && !self.hostname.isEmpty {
                self.userInfo = self.hostname
                self.hostname = ""
            }
            if self.schema == .unrecognized && self.userInfo.isEmpty && !self.hostname.isEmpty {
                self.userInfo = self.hostname
                self.hostname = ""
            }
        } else {
            self.schema = .unrecognized
            self.userInfo = normalizedUri
        }
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> String? {
        guard match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: string) else { return nil }
        return String(string[range])
    }

    var isHexId: Bool {
        let range = NSRange(location: 0, length: userInfo.utf16.count)
        return JamiURI.hexIdPattern?.firstMatch(in: userInfo, options: [], range: range) != nil
    }

    var isJami: Bool {
        return schema.isJamiType || (schema == .unrecognized && isHexId)
    }

    var hash: String? {
        return userInfo.isEmpty ? nil : userInfo
    }

    var uriString: String? {
        if userInfo.isEmpty { return nil }
        if schema.isJamiType || (schema == .unrecognized && isHexId) {
            return "jami:" + userInfo
        }
        if schema == .sip {
            var result = "sip:" + userInfo
            if !hostname.isEmpty {
                result += "@" + hostname
                if !port.isEmpty { result += ":" + port }
            }
            return result
        }
        return nil
    }
}

/// A link that opens a specific screen in the app, e.g. `talk9://user/<jamiId>`.
enum DeepLink: Equatable {
    /// Open the one-to-one conversation with an account, creating a temporary one
    /// when the peer is not a contact yet.
    case user(jamiId: String)
    /// Open an existing swarm conversation.
    case conversation(conversationId: String)

    static let scheme = "talk9"
    static let webHost = "talk9.co"

    /// Accepts both the custom scheme and the universal link declared in the
    /// apple-app-site-association file, e.g. `talk9://user/<id>` and
    /// `https://talk9.co/u/<id>`.
    init?(url: URL) {
        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        let route: String?
        let identifier: String?

        switch url.scheme?.lowercased() {
        case DeepLink.scheme:
            // `talk9://user/<id>` parses as host "user" and path "/<id>".
            route = url.host?.lowercased()
            identifier = segments.first
        case "https" where url.host?.lowercased() == DeepLink.webHost:
            // `https://talk9.co/u/<id>` carries both parts in the path.
            route = segments.first
            identifier = segments.dropFirst().first
        default:
            return nil
        }

        guard let identifier = identifier, DeepLink.isValidIdentifier(identifier) else {
            return nil
        }

        switch route {
        case "user", "u", "call":
            // `call` deliberately lands on the conversation instead of dialling:
            // opening a link must never place a call on the user's behalf.
            self = .user(jamiId: identifier)
        case "conversation", "c":
            self = .conversation(conversationId: identifier)
        default:
            // `/i/` (group invites) is declared in the AASA file but not handled
            // yet — accepting an invite needs more than opening a screen.
            return nil
        }
    }

    /// Both account ids and swarm conversation ids are 40 hexadecimal characters.
    /// Kept stricter than `String.isSHA1()`, which matches on a substring and would
    /// accept a padded identifier coming from an untrusted link.
    private static func isValidIdentifier(_ value: String) -> Bool {
        return value.count == 40 && value.allSatisfy { $0.isHexDigit }
    }
}
