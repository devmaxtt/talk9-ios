/*
 *  Copyright (C) 2017-2019 Savoir-faire Linux Inc.
 *
 *  Author: Andreas Traczyk <andreas.traczyk@savoirfairelinux.com>
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
import Network
import SwiftyBeaver
import RxSwift
import RxRelay

enum ConnectionType {
    case none
    case connected
}

class NetworkService {

    private let log = SwiftyBeaver.self

    var connectionState = BehaviorRelay<ConnectionType>(value: .none)

    lazy var connectionStateObservable: Observable<ConnectionType> = {
        return self.connectionState.asObservable()
    }()

    private var monitor: NWPathMonitor?
    private var lastStatus: NWPath.Status = .requiresConnection
    // [TALK9] R6: which interface types the current path uses. A WiFi↔cellular
    // handoff keeps status == .satisfied, so comparing status alone swallowed
    // the transition — no connectivityChanged reached the daemon and it kept
    // pushing on dead sockets until the 5-minute foreground timer fired (or
    // indefinitely during a backgrounded call). Comparing the interface set
    // catches the handoff.
    private var lastInterfaceSignature = ""
    // Trailing debounce for interface-only changes: one handoff fires several
    // path updates within ~2 s (both interfaces up, then one drops). Emitting
    // once after the path settles gives the daemon a single reconnect on the
    // FINAL interface instead of churn on the intermediates.
    private var pendingInterfaceChange: DispatchWorkItem?
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    init() {
        monitor = NWPathMonitor()
    }

    private static func interfaceSignature(_ path: NWPath) -> String {
        var parts = [String]()
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.cellular) { parts.append("cell") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("wired") }
        if path.usesInterfaceType(.other) { parts.append("other") }
        return parts.joined(separator: "+")
    }

    func monitorNetworkType() {
        monitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let signature = NetworkService.interfaceSignature(path)

            if self.lastStatus == path.status {
                // Same status — only interesting when a satisfied path moved
                // to a different interface set (WiFi↔cellular handoff).
                guard path.status == .satisfied,
                      signature != self.lastInterfaceSignature else { return }
                self.lastInterfaceSignature = signature
                print("Network interface changed: \(signature)")
                self.pendingInterfaceChange?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.connectionState.accept(.connected)
                }
                self.pendingInterfaceChange = work
                self.monitorQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
                return
            }

            self.pendingInterfaceChange?.cancel()
            self.lastStatus = path.status
            self.lastInterfaceSignature = signature

            switch path.status {
            case .satisfied:
                print("Connected to a network")
                self.connectionState.accept(.connected)
            case .unsatisfied, .requiresConnection:
                print("Disconnected from a network")
                self.connectionState.accept(.none)
            default:
                break
            }
        }
        monitor?.start(queue: monitorQueue)
    }
}
