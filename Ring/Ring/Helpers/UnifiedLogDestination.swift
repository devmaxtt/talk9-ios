/*
 *  Copyright (C) 2026 Talk9
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
import os
import SwiftyBeaver

/// Mirrors SwiftyBeaver output into the unified log so it can be read without a
/// debugger.
///
/// The stock `ConsoleDestination` writes with `print()`, which reaches stdout only —
/// readable in Xcode while the debugger is attached, and nowhere else. Force-quitting
/// the app ends the debug session with SIGKILL, so the relaunch-after-kill paths where
/// push delivery and account re-registration actually live produced no readable log at
/// all.
///
/// `ConsoleDestination.useNSLog` is not a fix either: it emits `NSLog("%@", message)`,
/// and a `%@` argument is redacted by the unified log, so every line arrives in
/// Console.app as `<private>` — present, and useless. Interpolated values have to be
/// declared public at the call to `os_log` itself, which is what this destination does
/// and what `NotificationService.log()` in the extension already did.
///
/// Registered alongside the console destination, in DEBUG builds only.
final class UnifiedLogDestination: BaseDestination {
    private let osLog = OSLog(subsystem: "m.talk.talk9", category: "Talk9")

    override func send(_ level: SwiftyBeaver.Level, msg: String, thread: String,
                       file: String, function: String, line: Int,
                       context: Any? = nil) -> String? {
        let formatted = super.send(level, msg: msg, thread: thread, file: file,
                                   function: function, line: line, context: context)
        let text = formatted ?? msg
        // .error rather than .debug: debug-level entries are dropped from the log
        // store unless the device is running a logging profile, which would put these
        // lines right back out of reach on a tester's phone.
        os_log("%{public}@", log: osLog, type: .error, text)
        return formatted
    }
}
