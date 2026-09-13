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

/// What the backend manifest says about the installed build.
enum AppUpdateStatus: Equatable {
    /// Installed version is current enough; show nothing.
    case upToDate
    /// Newer version exists, but this one still works — dismissible prompt.
    case optional(storeURL: URL)
    /// Installed version is below `min_version` — blocking prompt.
    case required(storeURL: URL)
}

/// Checks the installed build against the Talk9 version manifest.
///
/// Mirrors Android's `cx.ring.utils.AppUpdateChecker`. See `ANDROID_PARITY.md` §1.1.
///
/// The check is advisory: every failure path (no network, bad JSON, missing keys,
/// unparseable version) resolves to `.upToDate`. A version check must never block
/// launch or surface an error — the user did nothing wrong.
enum AppUpdateChecker {

    /// `app.talk9.co`, not `talk9.co` — matches Android's `AppConfig.BASE_URL`.
    private static let endpoint = URL(string: "https://app.talk9.co/api/app_list")!
    private static let timeout: TimeInterval = 10

    /// Fetches the manifest and reports what the UI should do.
    /// `completion` is always called on the main queue.
    static func check(session: URLSession = .shared,
                      completion: @escaping (AppUpdateStatus) -> Void) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        session.dataTask(with: request) { data, _, _ in
            let status = data.flatMap { parse($0) } ?? .upToDate
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    /// Reads the `ios` entry out of the manifest. Returns nil when anything is
    /// missing or malformed, which the caller treats as `.upToDate`.
    ///
    /// Expected shape:
    /// ```
    /// { "ios": { "min_version": "1.0.1",
    ///            "latest_version": "1.0.2",
    ///            "store_url": "https://apps.apple.com/app/id..." } }
    /// ```
    /// `current` defaults to the installed build; pass it explicitly in tests.
    static func parse(_ data: Data, current: String? = nil) -> AppUpdateStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let platform = root["ios"] as? [String: Any],
              let minVersion = platform["min_version"] as? String,
              let latestVersion = platform["latest_version"] as? String,
              let storeString = platform["store_url"] as? String,
              let storeURL = URL(string: storeString),
              let current = current ?? Constants.versionNumber else { return nil }

        return status(current: current,
                      minVersion: minVersion,
                      latestVersion: latestVersion,
                      storeURL: storeURL)
    }

    static func status(current: String,
                       minVersion: String,
                       latestVersion: String,
                       storeURL: URL) -> AppUpdateStatus {
        if isOlder(current, than: minVersion) { return .required(storeURL: storeURL) }
        if isOlder(current, than: latestVersion) { return .optional(storeURL: storeURL) }
        return .upToDate
    }

    /// Compares dotted versions **segment by segment as integers**.
    ///
    /// String comparison gets this wrong: "1.0.9" > "1.0.10" lexicographically,
    /// but 1.0.9 is the older build. Missing segments count as 0, so "1.0" == "1.0.0".
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0..<max(left.count, right.count) {
            let lseg = index < left.count ? left[index] : 0
            let rseg = index < right.count ? right[index] : 0
            if lseg < rseg { return true }
            if lseg > rseg { return false }
        }
        return false
    }
}
