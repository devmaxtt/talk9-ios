/*
 * Copyright (C) 2021-2025 Savoir-faire Linux Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA.
 */

import UserNotifications
import UIKit
import CallKit
import Foundation
import CoreFoundation
import os
import Darwin
import Contacts
import RxSwift
import Atomics

/*
 * This class is responsible for handling incoming notifications from the DHT proxy server.
 * The steps are as follows:
 *  1. The notification request is received as a JSON object and is processed to extract the necessary data
 *  2. If the main app is active, the notification data is saved and the app is notified to handle synchronization
 *     instead of the extension
 *  3. If the main app is not active, the notification data is used to start a data stream from the proxy server
 *     over HTTP
 *  4. The data stream is processed line by line, and each line is decrypted and processed
 *  5. The decrypted data is used to obtain the information needed to determine the action to take
 *  6. The action is taken, which may involve presenting a local notification or stopping the current backend
 *     instance and handing off control the foreground app (in the case of an incoming call)
 *
 * The class also handles the retrieval of contact names from the name server, which is done asynchronously.
 * In the case of a name being required, the notification is enqueued and the name is retrieved before the
 * notification is presented.
 *
 * The actions taken based on the notification data are as follows:
 *  - If the data is a call, the call is presented (the extension can be stopped as the foreground app will take over)
 *  - If the data is a message, the backend is started (if not already active) and events are parsed until the message
 *    body is received and enqueue for presentation
 *  - If the data is a file, the backend is started (if not already active) and events are parsed until the file is
 *    downloaded and the notification is enqueued for presentation
 *  - If the data is a clone request, the backend is started and events are parsed until the clone is completed
 *
 * Backend event handling is kept alive using a simple reference counting mechanism `itemsToPresent` and `syncCompleted`
 * which are incremented and decremented as events are processed and completed. When all events are processed and the
 * clone is completed, the backend is stopped. The HTTP stream is cancelled once all value IDs are processed or the
 * notification times out (25 seconds).
 */

// swiftlint:disable file_length

protocol DarwinNotificationHandler {
    func checkDarwinNotificationResponse(
        queryNotification: CFString,
        responseNotification: CFString,
        localNotificationName: Notification.Name,
        setupAction: (() -> Void)?
    ) -> Bool

    func listenForNotificationResponse(responseNotification: CFString, localNotificationName: NSNotification.Name, completion: @escaping (Bool) -> Void) -> NSObjectProtocol
}

enum NotificationField: String {
    case key
    case accountId = "to"
    case aps
}

enum LocalNotificationType: String {
    case message
    case file
}

struct NotificationConfig {
    let from: String
    var url: URL?
    let body: String
    let conversationId: String
    let groupTitle: String
}

// A local log helper that prints an easy to see log with the thread info
private let notifLogger = OSLog(subsystem: "m.talk.talk9.jamiNotificationExtension", category: "Talk9-Notif")
func log(_ messages: String...) {
    let message = messages.joined(separator: " ")
    os_log("%{public}@", log: notifLogger, type: .error, message)
    print("------ [\(Unmanaged.passUnretained(Thread.current).toOpaque())] \(message)")
}

// MARK: AutoDispatchGroup helper
class AutoDispatchGroup {
    private var taskIds = Set<String>()
    private let group = DispatchGroup()
    private let tasksQueue = DispatchQueue(label: Constants.appIdentifier + ".AutoDispatchGroup.queue")

    func enter(id: String) {
        tasksQueue.sync {
            if taskIds.contains(id) {
                log("Task with ID \(id) already exists")
            } else {
                log("AutoDispatchGroup entering new task: \(id)")
                taskIds.insert(id)
                group.enter()
            }
        }
    }

    func leave(id: String) {
        tasksQueue.sync {
            guard taskIds.contains(id) else { return }
            log("AutoDispatchGroup leaving task: \(id)")
            taskIds.remove(id)
            group.leave()
        }
    }

    func wait(timeout: DispatchTime = .distantFuture) -> DispatchTimeoutResult {
        group.wait(timeout: timeout)
    }
}

class HTTPStreamHandler: NSObject, URLSessionDataDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var dataBuffer = Data()
    private var task: URLSessionDataTask?
    private var subject = PublishSubject<String>()
    private let taskQueue = DispatchQueue(label: Constants.appIdentifier + ".HTTPStreamHandler.queue")

    func invalidateAndCancelSession() {
        session.invalidateAndCancel()
    }

    private func startTask(url: URL) {
        taskQueue.sync { [weak self] in
            guard let self = self else { return }
            self.task = self.session.dataTask(with: url)
            log("Starting URL Stream: \(url)")
            self.task?.resume()
        }
    }

    func startStreaming(from url: URL) -> Observable<String> {
        return subject
            .do(onSubscribe: { [weak self] in
                self?.startTask(url: url)
            })
            .do(onDispose: { [weak self] in
                _ = self?.cancelPendingDataTask()
            })
    }

    private func cancelPendingDataTask() -> Bool {
        taskQueue.sync { [weak self] in
            guard let self = self else { return false }
            if self.task?.state == .running {
                self.task?.cancel()
                return true
            }
            return false
        }
    }

    func cancelStreaming() {
        if cancelPendingDataTask() {
            log("Stream handling canceled")
            subject.onCompleted()
        }
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var receivedStrings = [String]()
        taskQueue.sync { [weak self] in
            guard let self = self else { return }
            self.dataBuffer.append(data)
            while let range = self.dataBuffer.range(of: "\n".data(using: .utf8)!) {
                let lineData = self.dataBuffer.subdata(in: 0..<range.lowerBound)
                self.dataBuffer.removeSubrange(0..<range.upperBound)
                if let lineString = String(data: lineData, encoding: .utf8) {
                    receivedStrings.append(lineString)
                }
            }
        }
        for string in receivedStrings {
            subject.onNext(string)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            self.subject.onError(error)
        } else {
            self.subject.onCompleted()
        }
    }
}

// MARK: NotificationService
class NotificationService: UNNotificationServiceExtension {
    typealias LocalNotification = (content: UNMutableNotificationContent, type: LocalNotificationType)

    private static let localNotificationName = Notification.Name(Constants.appIdentifier + ".appActive.internal")
    private static let localShareExtensionNotificationName = Notification.Name(Constants.appIdentifier + ".shareExtensionActive.internal")

    private let notificationTimeout = DispatchTimeInterval.seconds(25)
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent = UNMutableNotificationContent()

    // All asynchronous tasks are managed using the AutoDispatchGroup which tracks tasks using
    // IDs. Both the streaming and Jami backend tasks will be waited upon using this group.
    private let autoDispatchGroup = AutoDispatchGroup()
    private let httpStreamHandler = HTTPStreamHandler()
    private let disposeBag = DisposeBag()

    // The following objects are used to manage access to the Jami backend for synchronization
    private var accountIsActive = ManagedAtomic<Bool>(false)
    private var accountId: String = ""
    private var adapterService: AdapterService = AdapterService(withAdapter: Adapter())
    private var jamiTaskId: String = ""
    private var idsToProcess: Set<String> = []
    private var processAll: Bool = false
    private let taskPropertyQueue = DispatchQueue(label: Constants.appIdentifier + ".TaskProperty.queue")
    private var originalNotificationData: [String: String] = [:]
    // The following describe scheduled events and will be synchronized with the DispatchQueue
    private var itemsToPresent = 0
    private var syncCompleted = false
    private var waitForCloning = false

    // Set to true the first time a local notification is successfully scheduled,
    // so finish() knows to suppress the APNs placeholder duplicate.
    private var didPresentLocalNotification = false

    // Set to true when the daemon is started for this notification.
    // If daemon ran but didPresentLocalNotification is still false, it means the
    // message was already treated (processed by another extension instance) — suppress.
    private var didStartDaemon = false

    // Sender info extracted from decrypt, used as fallback when daemon sync times out
    private var pendingSenderId: String = ""
    private var pendingConvId: String = ""
    private var pendingSenderName: String = ""

    // When app is in background memory (appIsActive=true), skip daemon sync but still run DHT decrypt
    private var skipDaemonSync = false

    // Timestamp when this extension instance was created (used to reject stale cache entries)
    private let extensionStartTime = Date().timeIntervalSince1970

    // A queue of pending local notifications, waiting for a name lookup
    private let notificationQueue = DispatchQueue(label: Constants.appIdentifier + ".Notification.queue")
    private var pendingLocalNotifications = [String: [LocalNotification]]() // local notification waiting for name lookup
    private var pendingCalls = [String: [AnyHashable: Any]]() // calls waiting for name lookup
    private var pendingActiveCallNotifications = [String: (notification: LocalNotification, participants: [String])]() // active call notifications waiting for name lookup
    private var names = [String: String]() // map of peerId and best name
    private let thumbnailSize = 100

    deinit {
        removeNotificationExtensionQueryListener()
        httpStreamHandler.invalidateAndCancelSession()
    }

    // Entry point for processing incoming notification requests.
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        // Default to empty content so any crash or timeout shows nothing instead of the
        // raw APNs placeholder "hello". Real content is filled in by processMap / presentLocalNotification.
        self.bestAttemptContent = UNMutableNotificationContent()
        setupNotificationExtensionQueryListener()
        log("didReceive called — userInfo keys: \(request.content.userInfo.keys.map { String(describing: $0) })")

        Task {
            self.processNotificationRequest(request)
            _ = autoDispatchGroup.wait(timeout: .now() + notificationTimeout)
            self.finish()
        }
    }

    // Handles the initial processing of the notification request.
    private func processNotificationRequest(_ request: UNNotificationRequest) {
        let requestData = requestToDictionary(request: request)
        log("requestData keys: \(requestData.keys.sorted()), to=\(requestData["to"] ?? "NIL")")
        guard !requestData.isEmpty,
              let accountId = requestData[NotificationField.accountId.rawValue] else {
            log("FAIL: requestData empty or 'to' field missing")
            return
        }

        // Save notification data so the main app can call pushNotificationReceived when it wakes.
        saveDataIfNeeded(data: requestData)

        if appIsActive() {
            // App is in foreground — it will handle this push via handleNotification() /
            // pushNotificationReceived().  Extension must NOT show a banner here; doing so
            // would duplicate the in-app message delivery and create notification spam.
            log("[Talk9-Notif] App is active — deferring to main app, suppressing banner")
            return
        }

        guard !shareExtensionHasAccountActive(accountId: accountId) else {
            log("Share extension has this account active")
            return
        }

        guard !isResubscribe(accountId: accountId, data: requestData) else {
            log("This is a resubscribe notification")
            return
        }

        log("Handling new notification (app in background)")

        self.accountId = accountId
        self.originalNotificationData = requestData
        prepareAndStartStreaming(for: request, with: requestData)
    }

    // Prepares for and starts the data stream based on notification data.
    private func prepareAndStartStreaming(for request: UNNotificationRequest, with requestData: [String: String]) {
        guard let keyURL = getKeyURL(data: requestData) else {
            log("[Talk9-Notif] FAIL: keyURL is nil — ring_device.key missing for account \(requestData["to"] ?? "?")")
            return
        }
        let keyExists = FileManager.default.fileExists(atPath: keyURL.path)
        log("[Talk9-Notif] ring_device.key exists=\(keyExists) path=\(keyURL.path)")
        guard let treatedMessagesURL = getTreatedMessagesURL(data: requestData) else {
            log("[Talk9-Notif] FAIL: treatedMessagesURL is nil")
            return
        }
        guard let proxyURL = getProxyCaches(data: requestData) else {
            log("[Talk9-Notif] FAIL: proxyURL is nil — cachesPath or accountId missing")
            return
        }
        let url: URL
        if let cachedURL = getRequestURL(data: requestData, path: proxyURL) {
            url = cachedURL
            log("[Talk9-Notif] streaming from dhtproxy cache: \(url)")
        } else if let fallbackURL = getFallbackRequestURL(data: requestData) {
            url = fallbackURL
            log("[Talk9-Notif] dhtproxy cache missing, using fallback: \(url)")
        } else {
            log("[Talk9-Notif] FAIL: no proxy URL available (cache missing and no fallback)")
            return
        }

        // Transform the comma-separated ids string
        if let idsString = requestData["ids"] {
            self.idsToProcess = Set(idsString.split(separator: ",").map { String($0) })
        }
        self.processAll = self.idsToProcess.isEmpty

        startStreaming(from: url, for: request, keyURL: keyURL, treatedMessagesURL: treatedMessagesURL)
    }

    // Starts streaming data from a specified URL and processes received lines.
    private func startStreaming(from url: URL, for request: UNNotificationRequest, keyURL: URL, treatedMessagesURL: URL) {
        let taskId = UUID().uuidString
        autoDispatchGroup.enter(id: taskId)

        httpStreamHandler.startStreaming(from: url)
            .subscribe(onNext: { [weak self] line in
                self?.processStreamLine(line, with: request, keyURL: keyURL, treatedMessagesURL: treatedMessagesURL)
            }, onError: { [weak self] error in
                log("[Talk9-Notif] stream error: \(error)")
                self?.autoDispatchGroup.leave(id: taskId)
            }, onCompleted: { [weak self] in
                log("[Talk9-Notif] stream completed, pendingSenderId=\(self?.pendingSenderId.prefix(8) ?? "nil")")
                self?.autoDispatchGroup.leave(id: taskId)
            })
            .disposed(by: disposeBag)
    }

    // Processes each line received from the data stream.
    private func processStreamLine(_ line: String, with request: UNNotificationRequest, keyURL: URL, treatedMessagesURL: URL) {
        do {
            guard let jsonData = line.data(using: .utf8),
                  let map = try JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String: Any],
                  let id = map["id"] as? String,
                  map["cypher"] != nil else {
                log("Line doesn't contain a valid schema")
                return
            }

            guard idsToProcess.contains(id) || processAll else {
                log("Skipping line; ID is not in the list: \(id)")
                return
            }

            log("Processing ID: \(id)")
            idsToProcess.remove(id)
            processMap(map: map, keyURL: keyURL, treatedMessagesURL: treatedMessagesURL, userInfo: request.content.userInfo)
            if !processAll && idsToProcess.isEmpty {
                log("All IDs processed; Canceling stream")
                httpStreamHandler.cancelStreaming()
            }
        } catch {
            log("Stream decoding error: \(error) line: \(line)")
        }
    }

    private func processMap(map: [String: Any], keyURL: URL, treatedMessagesURL: URL, userInfo: [AnyHashable: Any]) {
        log("[Talk9-Notif] decrypt: keyPath=\(keyURL.path) accountId=\(self.accountId) keyExists=\(FileManager.default.fileExists(atPath: keyURL.path))")
        let result = adapterService.decrypt(keyPath: keyURL.path, accountId: self.accountId, messagesPath: treatedMessagesURL.path, value: map)
        log("Notification type: \(result)")
        switch result {
        case .call(let peerId, let hasVideo):
            ({ [weak self] (peerId, hasVideo) in
                guard let self = self else {
                    return
                }
                var info: [AnyHashable: Any] = [:]
                // Include all original notification data fields
                for (key, value) in self.originalNotificationData {
                    info[key] = value
                }
                // Add call-specific fields
                info["peerId"] = peerId
                info["hasVideo"] = hasVideo
                info["accountId"] = self.accountId
                let name = self.bestName(accountId: self.accountId, contactId: peerId)
                // jami will be started. Set accounts to not active state
                if self.accountIsActive.compareExchange(expected: true, desired: false, ordering: .relaxed).original {
                    self.adapterService.stop(accountId: self.accountId)
                }
                info["displayName"] = name.isEmpty ? peerId : name
                self.pendingCalls[peerId] = info

                if name.isEmpty {
                    // Enter the dispatch group to wait for the address lookup process to finish.
                    self.autoDispatchGroup.enter(id: peerId)
                    self.startAddressLookup(address: peerId)
                }
            })(peerId, "\(hasVideo)")
            return
        case .gitMessage(let convId, let peerId):
            // Store sender ID so finish() can show a fallback notification if daemon sync times out
            self.pendingSenderId = peerId
            self.pendingConvId = convId
            // Populate userInfo with the keys AppDelegate expects so a tap on this
            // banner can navigate to the conversation. Without these keys the very
            // first guard in handleNotificationActions fails (accountID is nil) and
            // the app opens without navigating anywhere.
            self.bestAttemptContent.userInfo = [
                Constants.NotificationUserInfoKeys.accountID.rawValue: self.accountId,
                Constants.NotificationUserInfoKeys.participantID.rawValue: peerId,
                Constants.NotificationUserInfoKeys.conversationID.rawValue: convId
            ]
            // Always set a baseline body so contentHandler never delivers empty content
            // (empty content on some iOS versions causes fallback to the raw APNs "hello" payload).
            self.bestAttemptContent.body = "New message"
            // Immediately update bestAttemptContent so even a timeout shows meaningful content
            if !peerId.isEmpty {
                // 1. Try local vCard first (fast, sync)
                let localName = self.contactProfileName(accountId: self.accountId, contactId: peerId)
                let displayName = localName ?? String(peerId.prefix(16))
                self.bestAttemptContent.title = displayName
                log("[Talk9-Notif] bestAttemptContent set: '\(displayName)' vCard=\(localName != nil)")
                // 2. Try name server lookup (async, may find registered username)
                self.lookupSenderName(peerId: peerId)
            }
            self.handleGitMessage(convId: convId, loadAll: convId.isEmpty) // async
        case .clone:
            // Should start daemon and wait until clone completed
            self.taskPropertyQueue.sync { self.waitForCloning = true }
            self.handleGitMessage(convId: "", loadAll: false) // async
        case .unknown:
            break
        }
    }

    override func serviceExtensionTimeWillExpire() {
        log("Notification handling timeout")
        finish()
    }

    private func isResubscribe(accountId: String, data: [String: String]) -> Bool {
        // A resubscribe push keeps the DHT subscription alive.
        // Do NOT start the daemon here — doing so triggers TURN allocation which
        // crashes the extension process (EXC_BAD_ACCESS), causing iOS to fall back
        // to the raw APNs placeholder "hello". The main app's daemon handles DHT
        // resubscription when the app is alive; if the app is dead, DHT reconnects
        // automatically on next launch.
        return data["timeout"] != nil && data["timeout"] != "<null>"
    }

    private func handleGitMessage(convId: String, loadAll: Bool) {
        // Never start the daemon inside the notification extension.
        // Starting the daemon (libjami::start) during extension init triggers SSL/TURN
        // connections that crash the extension process (EXC_BAD_ACCESS). When the
        // extension process crashes iOS falls back to the raw APNs "hello" placeholder.
        // Instead, always read from the shared cache written by the main app daemon.
        log("[Talk9-Notif] handleGitMessage: using cache (no daemon), convId='\(pendingConvId)' sender=\(pendingSenderId.prefix(16))")
        let waitId = UUID().uuidString
        // Capture the group directly so defer always runs even if self is deallocated.
        // If self were nil at the asyncAfter closure, the old guard-before-defer pattern
        // would skip the leave(), leaking the group entry and causing a 25-second timeout
        // — after which iOS would fall back to showing the raw APNs "hello" placeholder.
        let group = autoDispatchGroup
        autoDispatchGroup.enter(id: waitId)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            defer { group.leave(id: waitId) }
            guard let self = self else { return }
            guard !self.pendingSenderId.isEmpty,
                  let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else { return }
            // Only accept cache entries written within 2 seconds before this extension
            // instance started (covers clock skew / daemon-faster-than-extension races).
            // The old 10s grace was too large: it would pick up already-read messages if
            // the user received one within the preceding 10s and then a new push arrived.
            let freshThreshold = self.extensionStartTime - 2.0
            var cachedBody: String?

            func freshBody(from entry: [AnyHashable: Any]?) -> String? {
                guard let entry = entry,
                      let body = entry["body"] as? String, !body.isEmpty,
                      let ts = entry["ts"] as? TimeInterval,
                      ts >= freshThreshold else { return nil }
                return body
            }

            // 1. Try per-conversation key (convId present in push payload)
            if !self.pendingConvId.isEmpty {
                let convKey = Constants.talk9LastMessageKeyPrefix + self.accountId + "_" + self.pendingConvId
                if let body = freshBody(from: defaults.dictionary(forKey: convKey)) {
                    cachedBody = body
                    log("[Talk9-Notif] cache: fresh conv key '\(body.prefix(40))'")
                }
            }
            // 2. Fall back to per-sender key (convId empty or conv key missed)
            if cachedBody == nil {
                let senderKey = Constants.talk9LastMessageKeyPrefix + "sender_" + self.accountId + "_" + self.pendingSenderId
                if let body = freshBody(from: defaults.dictionary(forKey: senderKey)) {
                    cachedBody = body
                    log("[Talk9-Notif] cache: fresh sender key '\(body.prefix(40))'")
                }
            }
            if let body = cachedBody {
                self.bestAttemptContent.body = body
            } else {
                log("[Talk9-Notif] cache: miss or stale after 2s — showing 'New message'")
            }
        }
        return

    }

    private func verifyTasksStatus() {
        // waiting for lookup
        self.notificationQueue.sync {
            if !pendingCalls.isEmpty || !pendingLocalNotifications.isEmpty {
                return
            }
        }
        self.taskPropertyQueue.sync {
            // We could finish in two cases:
            // 1. we did not start account we are not waiting for the signals from the daemon
            // 2. conversation synchronization completed and all files downloaded
            if !self.accountIsActive.load(ordering: .relaxed) ||
                (self.syncCompleted && self.itemsToPresent == 0 && !self.waitForCloning) {
                self.autoDispatchGroup.leave(id: jamiTaskId)
            }
        }
    }

    private func finish() {
        removeNotificationExtensionQueryListener()
        if self.accountIsActive.compareExchange(expected: true, desired: false, ordering: .relaxed).original {
            self.adapterService.stop(accountId: self.accountId)
        } else {
            self.adapterService.removeDelegate()
        }
        // cleanup pending notifications
        self.notificationQueue.sync {
            if !self.pendingCalls.isEmpty, let info = self.pendingCalls.first?.value {
                self.presentCall(info: info)
            } else {
                for notifications in pendingLocalNotifications {
                    for notification in notifications.value {
                        self.presentLocalNotification(notification: notification)
                    }
                }
                pendingLocalNotifications.removeAll()
            }
        }
        self.httpStreamHandler.cancelStreaming()
        if let contentHandler = contentHandler {
            if didPresentLocalNotification {
                // Real notification already shown via UNUserNotificationCenter — suppress APNs duplicate
                bestAttemptContent.title = ""
                bestAttemptContent.body = ""
                log("[Talk9-Notif] finish: local notif shown, suppressing APNs duplicate")
            } else if didStartDaemon {
                // Daemon ran but showed nothing — message was already treated by another
                // extension instance. Suppress to prevent a duplicate "New message" banner.
                bestAttemptContent.title = ""
                bestAttemptContent.body = ""
                log("[Talk9-Notif] finish: daemon ran but no notification shown — suppressing duplicate")
            } else if bestAttemptContent.body.isEmpty {
                // No content was produced (resubscribe, failed URL lookups, unknown decrypt type, etc.).
                // iOS only falls back to the raw APNs "hello" when the extension CRASHES or TIMES OUT
                // without calling contentHandler.  When we call contentHandler ourselves — even with
                // completely empty title + body — iOS uses our empty content and shows nothing
                // (no banner, no sound).  Using a space here was wrong: it caused iOS to display a
                // silent "Talk9" banner with an invisible body.  Leave both empty so iOS suppresses
                // the banner entirely.
                bestAttemptContent.title = ""
                bestAttemptContent.body = ""
                log("[Talk9-Notif] finish: suppressing — no content (resubscribe / unknown decrypt)")
            } else {
                // bestAttemptContent was already updated in processMap (decrypt) and lookupSenderName
                log("[Talk9-Notif] finish: title=\(bestAttemptContent.title) body=\(bestAttemptContent.body.prefix(40))")
            }
            contentHandler(self.bestAttemptContent)
        }
        log("Finished handling notification")
    }

    private func appIsActive() -> Bool {
        return checkDarwinNotificationResponse(
            queryNotification: Constants.notificationReceived,
            responseNotification: Constants.notificationAppIsActive,
            localNotificationName: NotificationService.localNotificationName,
            setupAction: nil
        )
    }

    private func shareExtensionHasAccountActive(accountId: String) -> Bool {
        return checkDarwinNotificationResponse(
            queryNotification: Constants.notificationShareExtensionIsActive,
            responseNotification: Constants.notificationShareExtensionResponse,
            localNotificationName: NotificationService.localShareExtensionNotificationName,
            setupAction: nil
        )
    }

    private func setupNotificationExtensionQueryListener() {
        // If we currently process notification, we should prevent share extension from set account
        // active, or both, share extension and notification extension will have incorrect state.
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(notificationCenter,
                                        observer, { (_, observer, _, _, _) in
                                            guard let observer = observer else { return }
                                            let notificationService = Unmanaged<NotificationService>.fromOpaque(observer).takeUnretainedValue()
                                            notificationService.handleNotificationExtensionQuery()
                                        },
                                        Constants.notificationExtensionIsActive,
                                        nil,
                                        .deliverImmediately)
    }

    private func removeNotificationExtensionQueryListener() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(notificationCenter, observer, CFNotificationName(Constants.notificationExtensionIsActive), nil)
    }

    private func handleNotificationExtensionQuery() {
        // Respond if we have an active account
        if accountIsActive.load(ordering: .relaxed) {
            CFNotificationCenterPostNotification(notificationCenter,
                                                 CFNotificationName(Constants.notificationExtensionResponse),
                                                 nil,
                                                 nil,
                                                 true)
        }
    }

    private func saveDataIfNeeded(data: [String: String]) {
        guard let userDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else {
            return
        }
        var notificationData = [[String: String]]()
        if let existingData = userDefaults.object(forKey: Constants.notificationData) as? [[String: String]] {
            notificationData = existingData
        }
        notificationData.append(data)
        userDefaults.set(notificationData, forKey: Constants.notificationData)
    }

    private func requestToDictionary(request: UNNotificationRequest) -> [String: String] {
        var dictionary = [String: String]()
        let userInfo = request.content.userInfo
        for key in userInfo.keys {
            /// "aps" is a field added for alert notification type, so it could be received in the extension. This field is not needed by dht
            if String(describing: key) == NotificationField.aps.rawValue {
                continue
            }
            if let value = userInfo[key] {
                let keyString = String(describing: key)
                let valueString = String(describing: value)
                dictionary[keyString] = valueString
            }
        }
        return dictionary
    }
}

// MARK: Name retrieval
extension NotificationService {
    private func bestName(accountId: String, contactId: String) -> String {
        if let name = self.names[contactId], !name.isEmpty {
            return name
        }
        if let contactProfileName = self.contactProfileName(accountId: accountId, contactId: contactId),
           !contactProfileName.isEmpty {
            self.names[contactId] = contactProfileName
            return contactProfileName
        }
        let registeredName = self.adapterService.getNameFor(address: contactId, accountId: accountId)
        if !registeredName.isEmpty {
            self.names[contactId] = registeredName
        }
        return registeredName
    }

    private func startAddressLookup(address: String) {
        var nameServer = self.adapterService.getNameServerFor(accountId: self.accountId)
        nameServer = ensureURLPrefix(urlString: nameServer)
        let urlString = nameServer + "/addr/" + address
        guard let url = URL(string: urlString) else {
            self.lookupCompleted(address: address)
            return
        }
        let defaultSession = URLSession(configuration: .default)
        let task = defaultSession.dataTask(with: url) {[weak self](data, response, _) in
            guard let self = self else { return }
            var name: String?
            defer {
                self.lookupCompleted(address: address)
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let data = data else {
                return
            }
            do {
                guard let map = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: String] else { return }
                if map["name"] != nil {
                    name = map["name"]
                    self.names[address] = name
                }
            } catch {
                log("Serialization failed: \(error)")
            }
        }
        task.resume()
    }

    private func ensureURLPrefix(urlString: String) -> String {
        var urlWithPrefix = urlString
        if !urlWithPrefix.hasPrefix("http://") && !urlWithPrefix.hasPrefix("https://") {
            urlWithPrefix = "http://" + urlWithPrefix
        }
        return urlWithPrefix
    }

    private func lookupCompleted(address: String) {
        let name = self.names[address]
        self.notificationQueue.sync { [weak self] in
            guard let self = self else { return }
            for call in pendingCalls where call.key == address {
                var info = call.value
                if let name = name {
                    info["displayName"] = name
                }
                // Leave group after updating name
                self.autoDispatchGroup.leave(id: address)
                return
            }

            if let (notification, participants) = self.pendingActiveCallNotifications[address],
               let accountId = notification.content.userInfo[Constants.NotificationUserInfoKeys.accountID.rawValue] as? String {
                self.handleActiveCallNotification(notification: notification, participants: participants, accountId: accountId)
                return
            }

            for pending in pendingLocalNotifications where pending.key == address {
                let notifications = pending.value
                for notification in notifications {
                    if let name = name {
                        notification.content.title = name
                    }
                    presentLocalNotification(notification: notification)
                }
                pendingLocalNotifications.removeValue(forKey: address)
            }
        }
    }
}

// MARK: Paths and URLs
extension NotificationService {
    private func getRequestURL(data: [String: String], proxyURL: URL) -> URL? {
        guard let key = data[NotificationField.key.rawValue] else {
            return nil
        }
        return proxyURL.appendingPathComponent(key)
    }

    private func getRequestURL(data: [String: String], path: URL) -> URL? {
        guard let key = data[NotificationField.key.rawValue],
              let jsonData = NSData(contentsOf: path) as? Data else {
            return nil
        }
        guard let map = try? JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String: String],
              var proxyAddress = map.first?.value else {
            return nil
        }

        proxyAddress = ensureURLPrefix(urlString: proxyAddress)
        guard let urlPrpxy = URL(string: proxyAddress) else { return nil }
        return urlPrpxy.appendingPathComponent(key)
    }

    private func getKeyURL(data: [String: String]) -> URL? {
        guard let documentsPath = Constants.documentsPath,
              let accountId = data[NotificationField.accountId.rawValue] else {
            return nil
        }
        return documentsPath.appendingPathComponent(accountId).appendingPathComponent("ring_device.key")
    }

    private func getTreatedMessagesURL(data: [String: String]) -> URL? {
        guard let cachesPath = Constants.cachesPath,
              let accountId = data[NotificationField.accountId.rawValue] else {
            return nil
        }
        return cachesPath.appendingPathComponent(accountId).appendingPathComponent("treatedMessages")
    }

    private func getProxyCaches(data: [String: String]) -> URL? {
        guard let cachesPath = Constants.cachesPath,
              let accountId = data[NotificationField.accountId.rawValue] else {
            return nil
        }
        return cachesPath.appendingPathComponent(accountId).appendingPathComponent("dhtproxy")
    }

    private func lookupSenderName(peerId: String) {
        let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier)
        let nameServer = defaults?.string(forKey: "nameServer_\(self.accountId)") ?? "https://app.talk9.co"
        let urlString = (nameServer.hasPrefix("http") ? nameServer : "https://" + nameServer) + "/addr/" + peerId
        guard let url = URL(string: urlString) else { return }
        log("[Talk9-Notif] name lookup URL: \(urlString)")
        let taskId = "senderName_\(peerId)"
        // Capture the group directly so defer always fires even if self is deallocated
        // (same reason as in handleGitMessage — prevents a stuck dispatch group entry
        // that would cause the 25-second timeout and iOS "hello" fallback).
        let group = self.autoDispatchGroup
        self.autoDispatchGroup.enter(id: taskId)
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            defer { group.leave(id: taskId) }
            if let error = error {
                log("[Talk9-Notif] name lookup error: \(error)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let rawBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
            log("[Talk9-Notif] name lookup status=\(statusCode) body=\(rawBody)")
            guard let self = self,
                  let data = data,
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let name = map["name"], !name.isEmpty else {
                return
            }
            log("[Talk9-Notif] resolved sender name: \(name)")
            self.names[peerId] = name
            self.pendingSenderName = name
            // Update bestAttemptContent immediately so it shows the real name
            self.bestAttemptContent.title = name
        }.resume()
    }

    private func getFallbackRequestURL(data: [String: String]) -> URL? {
        guard let key = data[NotificationField.key.rawValue],
              let accountId = data[NotificationField.accountId.rawValue] else {
            return nil
        }
        let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier)
        let proxyServer = defaults?.string(forKey: "proxyServer_\(accountId)") ?? "https://dht.talk9.co"
        let urlString = proxyServer.hasPrefix("http") ? proxyServer : "https://" + proxyServer
        return URL(string: urlString)?.appendingPathComponent(key)
    }

    private func contactProfileName(accountId: String, contactId: String) -> String? {
        guard let documents = Constants.documentsPath else { return nil }
        let uri = "ring:" + contactId
        let path = documents.path + "/" + "\(accountId)" + "/profiles/" + "\(Data(uri.utf8).base64EncodedString()).vcf"
        if !FileManager.default.fileExists(atPath: path) { return nil }

        return VCardUtils.getNameFromVCard(filePath: path)
    }
}

// MARK: DarwinNotificationHandler
extension NotificationService: DarwinNotificationHandler {
    func checkDarwinNotificationResponse(
        queryNotification: CFString,
        responseNotification: CFString,
        localNotificationName: Notification.Name,
        setupAction: (() -> Void)?
    ) -> Bool {
        let group = DispatchGroup()
        var nsObserverToken: NSObjectProtocol?

        defer {
            if let token = nsObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterRemoveObserver(notificationCenter, observer, CFNotificationName(responseNotification), nil)
            group.leave()
        }

        var hasResponse = false
        group.enter()

        setupAction?()

        nsObserverToken = self.listenForNotificationResponse(responseNotification: responseNotification, localNotificationName: localNotificationName) { _ in
            hasResponse = true
        }

        CFNotificationCenterPostNotification(notificationCenter, CFNotificationName(queryNotification), nil, nil, true)

        _ = group.wait(timeout: .now() + 0.3)

        return hasResponse
    }

    func listenForNotificationResponse(responseNotification: CFString, localNotificationName: NSNotification.Name, completion: @escaping (Bool) -> Void) -> NSObjectProtocol {
        let observer = Unmanaged.passUnretained(self).toOpaque()

        if responseNotification == Constants.notificationAppIsActive {
            CFNotificationCenterAddObserver(notificationCenter,
                                            observer, { (_, _, _, _, _) in
                                                NotificationCenter.default.post(name: NotificationService.localNotificationName,
                                                                                object: nil,
                                                                                userInfo: nil)
                                            },
                                            responseNotification,
                                            nil,
                                            .deliverImmediately)
        } else if responseNotification == Constants.notificationShareExtensionResponse {
            CFNotificationCenterAddObserver(notificationCenter,
                                            observer, { (_, _, _, _, _) in
                                                NotificationCenter.default.post(name: NotificationService.localShareExtensionNotificationName,
                                                                                object: nil,
                                                                                userInfo: nil)
                                            },
                                            responseNotification,
                                            nil,
                                            .deliverImmediately)
        }

        return NotificationCenter.default.addObserver(forName: localNotificationName, object: nil, queue: nil) { _ in
            completion(true)
        }
    }
}

// MARK: Present and update notifications
extension NotificationService {
    private func createAttachment(identifier: String, image: UIImage, options: [NSObject: AnyObject]?) -> UNNotificationAttachment? {
        let fileManager = FileManager.default
        let tmpSubFolderName = ProcessInfo.processInfo.globallyUniqueString
        let tmpSubFolderURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tmpSubFolderName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: tmpSubFolderURL, withIntermediateDirectories: true, attributes: nil)
            let imageFileIdentifier = identifier
            let fileURL = tmpSubFolderURL.appendingPathComponent(imageFileIdentifier)
            let imageData = image.jpegData(compressionQuality: 0.7)
            try imageData?.write(to: fileURL)
            let imageAttachment = try UNNotificationAttachment.init(identifier: identifier, url: fileURL, options: options)
            return imageAttachment
        } catch {}
        return nil
    }

    func createThumbnailImage(fileURLString: String) -> UIImage? {
        guard let escapedPath = fileURLString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        // Construct the file URL with the correct scheme and path
        guard let fileURL = URL(string: "file://" + escapedPath) else {
            return nil
        }

        let size = CGSize(width: thumbnailSize, height: thumbnailSize)

        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
              let downsampledImage = createDownsampledImage(imageSource: imageSource,
                                                            targetSize: size,
                                                            pixelWidth: pixelWidth,
                                                            pixelHeight: pixelHeight) else {
            return nil
        }
        return UIImage(cgImage: downsampledImage)
    }

    func createDownsampledImage(imageSource: CGImageSource, targetSize: CGSize, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let maxDimension = max(targetSize.width, targetSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }

    // A generic function that configures a notification with the given content and type, and returns the notification
    private func configureNotification(config: NotificationConfig, type: LocalNotificationType) -> LocalNotification {
        let content = UNMutableNotificationContent()
        content.sound = UNNotificationSound.default
        var data = [String: String]()
        data[Constants.NotificationUserInfoKeys.participantID.rawValue] = config.from
        data[Constants.NotificationUserInfoKeys.accountID.rawValue] = self.accountId
        data[Constants.NotificationUserInfoKeys.conversationID.rawValue] = config.conversationId
        content.userInfo = data
        switch type {
        case .message:
            content.body = config.body
        case .file:
            if let url = config.url {
                let imageName = url.lastPathComponent
                content.body = imageName
                if let image = createThumbnailImage(fileURLString: url.path),
                   let attachement = createAttachment(identifier: imageName, image: image, options: nil) {
                    content.attachments = [ attachement ]
                }
            }
        }
        if !config.groupTitle.isEmpty {
            content.title = config.groupTitle
        } else {
            content.title = self.bestName(accountId: self.accountId, contactId: config.from)
        }
        if content.title.isEmpty {
            content.title = config.from
        }
        return (content, type)
    }

    private func configureAndPresentNotification(config: NotificationConfig, type: LocalNotificationType) {
        let notif = self.configureNotification(config: config, type: type)
        // If the title is a URI, do a lookup and queue presentation
        if notif.content.title == config.from {
            enqueueNotificationForNameUpdate(notification: notif, peerId: config.from)
        } else {
            self.presentLocalNotification(notification: notif)
        }
    }

    private func presentLocalNotification(notification: LocalNotification) {
        let content = notification.content
        // Keep bestAttemptContent in sync so the contentHandler fallback also shows
        // the real sender name and message instead of the APNs placeholder "hello".
        self.bestAttemptContent.title = content.title
        self.bestAttemptContent.body = content.body
        if let attachment = content.attachments.first {
            self.bestAttemptContent.attachments = [attachment]
        }
        self.didPresentLocalNotification = true
        setNotificationCount(notification: content)
        let notificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.01, repeats: false)
        let notificationRequest = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: notificationTrigger)
        UNUserNotificationCenter.current().add(notificationRequest) { [weak self] (error) in
            if let error = error {
                log("Unable to Add Notification Request: (\(error), \(error.localizedDescription))")
            }
            guard let self = self else { return }
            self.taskPropertyQueue.sync { self.itemsToPresent -= 1 }
            self.verifyTasksStatus()
        }
    }

    private func presentCall(info: [AnyHashable: Any]) {
        // TODO: see if this should sync after daemon stop
        CXProvider.reportNewIncomingVoIPPushPayload(info, completion: { error in
            log("NotificationService", "Did report voip notification, error: \(String(describing: error))")
        })
        self.pendingCalls.removeAll()
        self.pendingLocalNotifications.removeAll()
    }

    private func enqueueNotificationForNameUpdate(notification: LocalNotification, peerId: String) {
        self.notificationQueue.sync {
            if var pending = pendingLocalNotifications[peerId] {
                pending.append(notification)
                pendingLocalNotifications[peerId] = pending
            } else {
                pendingLocalNotifications[peerId] = [notification]
            }
        }
        startAddressLookup(address: peerId)
    }

    private func setNotificationCount(notification: UNMutableNotificationContent) {
        guard let userDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else {
            return
        }

        if let count = userDefaults.object(forKey: Constants.notificationsCount) as? NSNumber {
            let new: NSNumber = count.intValue + 1 as NSNumber
            notification.badge = new
            userDefaults.set(new, forKey: Constants.notificationsCount)
        }
    }
}

// MARK: active calls
extension NotificationService {
    private func configureAndPresentCallNotification(config: NotificationConfig, calls: [ActiveCall], accountId: String) {
        let notification = configureNotification(config: config, type: .message)
        var info = notification.content.userInfo
        info[Constants.NotificationUserInfoKeys.callURI.rawValue] = calls.first?.constructURI()
        notification.content.userInfo = info
        notification.content.body = L10n.Calls.activeCallInConversation
        configureCallActions(notification: notification, calls: calls, info: &info)

        if let conversationTitle = getConversationTitle(accountId: accountId, conversationId: config.conversationId) {
            notification.content.title = conversationTitle
            presentLocalNotification(notification: notification)
        } else {
            handlePresentationWithoutconverationTitle(notification: notification, accountId: accountId, conversationId: config.conversationId)
        }
    }

    private func getConversationTitle(accountId: String, conversationId: String) -> String? {
        guard let convInfo = adapterService.getConversationInfo(accountId: accountId, conversationId: conversationId),
              let title = convInfo[ConversationAttributes.title.rawValue] else {
            return nil
        }
        return "\(title)"
    }

    private func handlePresentationWithoutconverationTitle(notification: LocalNotification, accountId: String, conversationId: String) {
        guard let participants = adapterService.getConversationMemebers(accountId: accountId, conversationId: conversationId),
              let localJamiId = adapterService.getAccountJamiId(accountId: accountId) else {
            return
        }

        let filteredParticipants = participants.filter { $0 != localJamiId }
        let participantNames = Dictionary(uniqueKeysWithValues: filteredParticipants.map {
            ($0, self.bestName(accountId: accountId, contactId: $0))
        })

        let nonEmptyNames = participantNames.filter { !$0.value.isEmpty }
        let remainingParticipants = participantNames.filter { $0.value.isEmpty }

        if nonEmptyNames.count >= 3 || remainingParticipants.isEmpty {
            buildTitleForNotification(notification: notification, nonEmptyNames: nonEmptyNames, totalCount: participantNames.count)
            self.presentLocalNotification(notification: notification)

            cleanupActiveCallNotifications(for: notification)
        } else {
            lookupParticipants(notification: notification, nonEmptyNames: nonEmptyNames, remainingParticipants: remainingParticipants, filteredParticipants: filteredParticipants)
        }
    }

    private func lookupParticipants(notification: LocalNotification, nonEmptyNames: [String: String], remainingParticipants: [String: String], filteredParticipants: [String]) {
        let neededLookups = min(3 - nonEmptyNames.count, remainingParticipants.count)
        let participantsToLookup = Array(remainingParticipants.keys.prefix(neededLookups))

        if let firstParticipant = participantsToLookup.first {
            storeAndStartLookup(notification: notification, participant: firstParticipant, participants: filteredParticipants)
        }

        participantsToLookup.forEach { startAddressLookup(address: $0) }
    }

    private func storeAndStartLookup(notification: LocalNotification, participant: String, participants: [String]) {
        notificationQueue.sync {
            pendingActiveCallNotifications[participant] = (notification, participants)
        }
        startAddressLookup(address: participant)
    }

    private func configureCallActions(notification: LocalNotification, calls: [ActiveCall], info: inout [AnyHashable: Any]) {
        let acceptVideoAction: UNNotificationAction
        let acceptAudioAction: UNNotificationAction

        if #available(iOS 15.0, *) {
            acceptVideoAction = UNNotificationAction(
                identifier: Constants.NotificationAction.acceptVideo.rawValue,
                title: Constants.NotificationActionTitle.acceptWithVideo.toString(),
                options: [.foreground, .authenticationRequired],
                icon: UNNotificationActionIcon(systemImageName: Constants.NotificationActionIcon.video.rawValue)
            )

            acceptAudioAction = UNNotificationAction(
                identifier: Constants.NotificationAction.acceptAudio.rawValue,
                title: Constants.NotificationActionTitle.acceptWithAudio.toString(),
                options: [.foreground, .authenticationRequired],
                icon: UNNotificationActionIcon(systemImageName: Constants.NotificationActionIcon.audio.rawValue)
            )

            notification.content.interruptionLevel = .timeSensitive
        } else {
            acceptVideoAction = UNNotificationAction(
                identifier: Constants.NotificationAction.acceptVideo.rawValue,
                title: Constants.NotificationActionTitle.acceptWithVideo.toString(),
                options: [.foreground, .authenticationRequired]
            )

            acceptAudioAction = UNNotificationAction(
                identifier: Constants.NotificationAction.acceptAudio.rawValue,
                title: Constants.NotificationActionTitle.acceptWithAudio.toString(),
                options: [.foreground, .authenticationRequired]
            )
        }

        let callCategory = UNNotificationCategory(
            identifier: Constants.NotificationCategory.call.rawValue,
            actions: [acceptVideoAction, acceptAudioAction],
            intentIdentifiers: [],
            options: [.customDismissAction, .hiddenPreviewsShowTitle]
        )

        UNUserNotificationCenter.current().setNotificationCategories([callCategory])

        notification.content.categoryIdentifier = Constants.NotificationCategory.call.rawValue
    }

    private func handleActiveCallNotification(notification: LocalNotification, participants: [String], accountId: String) {
        let participantNames = Dictionary(uniqueKeysWithValues: participants.map {
            ($0, self.bestName(accountId: accountId, contactId: $0))
        })

        let nonEmptyNames = participantNames.filter { !$0.value.isEmpty }
        let remainingParticipants = participantNames.filter { $0.value.isEmpty }

        if nonEmptyNames.count >= 3 || remainingParticipants.isEmpty {
            buildTitleForNotification(notification: notification, nonEmptyNames: nonEmptyNames, totalCount: participantNames.count)
            self.presentLocalNotification(notification: notification)

            cleanupActiveCallNotifications(for: notification)
        }
    }

    private func buildTitleForNotification(notification: LocalNotification, nonEmptyNames: [String: String], totalCount: Int) {
        var title: String
        if nonEmptyNames.count == 1 {
            title = nonEmptyNames.first!.value
        } else if nonEmptyNames.count == 2 {
            title = nonEmptyNames.map { $0.value }.joined(separator: " and ")
        } else {
            let firstThree = nonEmptyNames.prefix(3)
            let remainingCount = totalCount - 3
            title = firstThree.map { $0.value }.joined(separator: ", ")
            if remainingCount > 0 {
                title += " and \(remainingCount) others"
            }
        }
        notification.content.title = title
    }

    private func cleanupActiveCallNotifications(for notification: LocalNotification) {
        guard let conversationId = notification.content.userInfo[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String else { return }
        for (key, _) in self.pendingActiveCallNotifications {
            if let notif = self.pendingActiveCallNotifications[key]?.notification,
               notif.content.userInfo[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String == conversationId {
                self.pendingActiveCallNotifications.removeValue(forKey: key)
            }
        }
    }

}
