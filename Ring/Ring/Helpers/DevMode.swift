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

/// Developer mode gate. Mirrors Android's `cx.ring.utils.DevModeUtils`.
///
/// Connectivity settings (bootstrap, DHT proxy, TURN) stay read-only until this
/// is on. A wrong value there silently stops the account from connecting, and it
/// is not something a normal user ever needs to touch — while the people who do
/// need it can turn this on. See `ANDROID_PARITY.md` §1.7.
enum DevMode {
    private static let key = "talk9_dev_mode"

    /// Taps on the version label in About that toggle developer mode on.
    static let tapsRequired = 7
    /// Remaining-taps hints start once the user is this close, matching Android.
    static let hintThreshold = 3

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Outcome of one tap on the version label.
    enum TapResult: Equatable {
        /// Nothing to show yet.
        case ignored
        /// Still `remaining` taps away from turning it on.
        case countingDown(remaining: Int)
        case enabled
        case disabled
    }

    /// Applies one tap to `count` and reports what the UI should say.
    /// `count` is reset by this call whenever the mode flips.
    static func registerTap(count: inout Int) -> TapResult {
        if isEnabled {
            isEnabled = false
            count = 0
            return .disabled
        }

        count += 1
        if count >= tapsRequired {
            isEnabled = true
            count = 0
            return .enabled
        }
        if count >= tapsRequired - hintThreshold {
            return .countingDown(remaining: tapsRequired - count)
        }
        return .ignored
    }
}
