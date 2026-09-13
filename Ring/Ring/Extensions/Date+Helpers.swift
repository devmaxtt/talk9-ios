/*
 *  Copyright (C) 2017-2019 Savoir-faire Linux Inc.
 *
 *  Author: Silbino Gonçalves Matado <silbino.gmatado@savoirfairelinux.com>
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

extension Date {
    func dayNumberOfWeek() -> Int? {
        return Calendar.current.dateComponents([.weekday], from: self).weekday
    }

    func dayOfWeek() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE"
        return dateFormatter.string(from: self)
    }

    func conversationTimestamp() -> String {
        let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter
        }()
        // .short follows the device's 12/24-hour setting; a hardcoded "HH:mm"
        // showed 24-hour time to users who had picked 12-hour.
        let hourFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter
        }()
        let calendar = Calendar.current

        if calendar.isDateInToday(self) {
            return hourFormatter.string(from: self)
        }
        if calendar.isDateInYesterday(self) {
            return L10n.Smartlist.yesterday
        }
        // Day name for the past week. Counting elapsed days rather than comparing
        // week-of-year keeps Saturday readable on Monday, when the two fall in
        // different weeks.
        let daysApart = calendar.dateComponents([.day],
                                                from: calendar.startOfDay(for: self),
                                                to: calendar.startOfDay(for: Date())).day ?? 0
        if (0..<7).contains(daysApart) {
            return self.dayOfWeek()
        }
        return dateFormatter.string(from: self)
    }

    func getTimeLabelString() -> String {
        let currentDateTime = Date()

        // prepare formatter
        let dateFormatter = DateFormatter()

        if Calendar.current.compare(currentDateTime, to: self, toGranularity: .day) == .orderedSame {
            // age: [0, received the previous day[
            dateFormatter.dateFormat = "h:mma"
        } else if Calendar.current.compare(currentDateTime, to: self, toGranularity: .weekOfYear) == .orderedSame {
            // age: [received the previous day, received 7 days ago[
            dateFormatter.dateFormat = "E h:mma"
        } else if Calendar.current.compare(currentDateTime, to: self, toGranularity: .year) == .orderedSame {
            // age: [received 7 days ago, received the previous year[
            dateFormatter.dateFormat = "MMM d, h:mma"
        } else {
            // age: [received the previous year, inf[
            dateFormatter.dateFormat = "MMM d, yyyy h:mma"
        }

        // generate the string containing the message time
        return dateFormatter.string(from: self).uppercased()
    }

}
