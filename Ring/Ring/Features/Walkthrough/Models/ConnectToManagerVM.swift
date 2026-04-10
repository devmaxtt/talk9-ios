/*
 *  Copyright (C) 2024 Savoir-faire Linux Inc.
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
import RxSwift
import SwiftUI

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: LogType
    let content: String

    enum LogType {
        case request, response

        var label: String {
            switch self {
            case .request: return "REQUEST →"
            case .response: return "RESPONSE ←"
            }
        }

        var color: Color {
            switch self {
            case .request: return .blue
            case .response: return .green
            }
        }
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

class ConnectToManagerVM: ObservableObject {
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var server: String = "app.talk9.co"
    @Published var isTextFieldFocused: Bool = false
    @Published var debugLogs: [DebugLogEntry] = []
    @Published var filterText: String = ""

    var connectAction: (_ username: String, _ password: String, _ server: String, _ responseLog: @escaping (String) -> Void) -> Void

    var isSignInDisabled: Bool {
        username.isEmpty || password.isEmpty || server.isEmpty
    }

    var signInButtonColor: Color {
        return isSignInDisabled ? Color(UIColor.secondaryLabel) : .jamiColor
    }

    var filteredLogs: [DebugLogEntry] {
        guard !filterText.isEmpty else { return debugLogs }
        return debugLogs.filter { $0.content.localizedCaseInsensitiveContains(filterText) }
    }

    init(with injectionBag: InjectionBag,
         connectAction: @escaping (_ username: String, _ password: String, _ server: String, _ responseLog: @escaping (String) -> Void) -> Void) {
        self.connectAction = connectAction
    }

    func connect() {
        if !isSignInDisabled {
            let requestContent = "Server: \(server)\nUsername: \(username)\nPassword: ********"
            debugLogs.append(DebugLogEntry(timestamp: Date(), type: .request, content: requestContent))
            connectAction(username, password, server) { [weak self] response in
                DispatchQueue.main.async {
                    self?.debugLogs.append(DebugLogEntry(timestamp: Date(), type: .response, content: response))
                }
            }
        }
    }
}
