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
    private var requestIdentifier: String = ""

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

    // [TALK9] R3: set when this push is a burst follower. finish() removes the
    // predecessor's banner right before delivering ours, so a burst collapses
    // to one refreshing banner instead of a stack — without ever silencing a
    // genuinely new second message inside the window.
    private var replacePreviousBannerId: String?

    // Set to true when the daemon is started for this notification.
    // If daemon ran but didPresentLocalNotification is still false, it means the
    // message was already treated (processed by another extension instance) — suppress.
    private var didStartDaemon = false

    // [TALK9] Set when finish() hands an incoming call to CallKit (presentCall).
    // The APNs placeholder must then be suppressed — CallKit already presents the
    // call UI, a stray "Talk9 / New message" banner on top of it is noise.
    private var didPresentCall = false

    // [TALK9] finish() can be reached from two racing places: the didReceive Task
    // (after the dispatch-group wait) and serviceExtensionTimeWillExpire.
    // contentHandler must only be consumed once — later calls are no-ops.
    private var didFinish = ManagedAtomic<Bool>(false)

    // Set to true for pushes that must never show any notification (resubscribe, app active).
    // When false and decryption fails, we fall back to the original APNs "New message" title
    // instead of delivering a blank no-title notification.
    private var shouldSuppressCompletely = false

    // Set to true when decrypt yields a real message type (.gitMessage / .call / .clone).
    // If false at finish(), the push was for a non-message DHT event (typing indicator,
    // read receipt, sync metadata, etc.) or an already-consumed message. Server cannot
    // filter these because `pt` field in OpenDHT push payload is always empty — they
    // have no DHT value type info. iOS must suppress to avoid spam from server placeholder.
    private var decryptYieldedRealMessage = false

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
        self.requestIdentifier = request.identifier
        // Start with the original APNs content so failed-decrypt cases fall back to
        // "New message" instead of a blank no-title notification.
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        setupNotificationExtensionQueryListener()

        let userInfoKeys = request.content.userInfo.keys.map { String(describing: $0) }.sorted()
        NSLog("[Talk9-Push] ▶ didReceive id=%@ keys=%@", request.identifier, userInfoKeys.joined(separator: ","))
        // Log the raw aps alert so we can see what the server actually sends
        if let aps = request.content.userInfo["aps"] as? [String: Any] {
            NSLog("[Talk9-Push]   aps=%@", aps.description)
        }

        Task {
            self.processNotificationRequest(request)
            _ = autoDispatchGroup.wait(timeout: .now() + notificationTimeout)
            self.finish()
        }
    }

    // Handles the initial processing of the notification request.
    private func processNotificationRequest(_ request: UNNotificationRequest) {
        let requestData = requestToDictionary(request: request)
        guard !requestData.isEmpty,
              let accountId = requestData[NotificationField.accountId.rawValue] else {
            NSLog("[Talk9-Push] ✗ SKIP — requestData empty or 'to' missing")
            return
        }

        let hasTimeout = requestData["timeout"] != nil && requestData["timeout"] != "<null>"
        let convId     = requestData["conversation_id"] ?? requestData["convId"] ?? ""
        let from       = requestData["from"] ?? ""
        NSLog("[Talk9-Push]   to=%@ from=%@ convId=%@ timeout=%@",
              String(accountId.prefix(8)), String(from.prefix(16)),
              String(convId.prefix(8)), hasTimeout ? (requestData["timeout"] ?? "") : "no")

        saveDataIfNeeded(data: requestData)

        if appIsActive() {
            NSLog("[Talk9-Push] ✗ SKIP — app is active (in-app will handle)")
            shouldSuppressCompletely = true
            return
        }

        guard !shareExtensionHasAccountActive(accountId: accountId) else {
            NSLog("[Talk9-Push] ✗ SKIP — share extension active")
            shouldSuppressCompletely = true
            return
        }

        guard !isResubscribe(accountId: accountId, data: requestData) else {
            NSLog("[Talk9-Push] ✗ SKIP — resubscribe (timeout=%@)", requestData["timeout"] ?? "")
            shouldSuppressCompletely = true
            return
        }

        NSLog("[Talk9-Push] ✓ PROCESS — app in background, starting stream")
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
        NSLog("[Talk9-Push]   stream line bytes=%@", "\(line.utf8.count)")
        do {
            guard let jsonData = line.data(using: .utf8),
                  let map = try JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String: Any],
                  let id = map["id"] as? String,
                  map["cypher"] != nil else {
                NSLog("[Talk9-Push]   ✗ stream line invalid (no id/cypher) preview=%@", String(line.prefix(120)))
                log("Line doesn't contain a valid schema")
                return
            }
            let cypherLen: Int = {
                if let c = map["cypher"] as? String { return c.count }
                if let c = map["cypher"] as? [Any] { return c.count }
                return -1
            }()
            let mapKeys = map.keys.sorted().joined(separator: ",")
            NSLog("[Talk9-Push]   stream entry id=%@ cypher_len=%@ keys=%@",
                  String(id.prefix(12)), "\(cypherLen)", mapKeys)

            guard idsToProcess.contains(id) || processAll else {
                // [TALK9-DIAG] Probe the value the server did NOT name. If this
                // one decrypts while the named one throws, the `ids` field is
                // pointing at the wrong value (e.g. the copy encrypted for a
                // different device of this account) and the fix is to fall back
                // to the rest of the stream instead of giving up. Costs one
                // extra decrypt per skipped value — diagnostics only.
                let probe = adapterService.decrypt(keyPath: keyURL.path,
                                                   accountId: self.accountId,
                                                   messagesPath: treatedMessagesURL.path,
                                                   value: map)
                NSLog("[Talk9-Push]   ✗ id not in idsToProcess: %{public}@ probe=%{public}@",
                      id, String(describing: probe))
                Self.diagAppend("SKIP    id=\(id) probe=\(probe) wanted=[\(idsToProcess.sorted().joined(separator: ","))]")
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
        let keyExists = FileManager.default.fileExists(atPath: keyURL.path)
        let treatedExists = FileManager.default.fileExists(atPath: treatedMessagesURL.path)
        let mapKeys = map.keys.sorted().joined(separator: ",")
        NSLog("[Talk9-Push]   ▸ decrypt call: acctId=%@ keyExists=%@ treatedExists=%@ mapKeys=%@",
              String(self.accountId.prefix(12)),
              keyExists ? "Y" : "N",
              treatedExists ? "Y" : "N",
              mapKeys)
        log("[Talk9-Notif] decrypt: keyPath=\(keyURL.path) accountId=\(self.accountId) keyExists=\(keyExists)")
        let result = adapterService.decrypt(keyPath: keyURL.path, accountId: self.accountId, messagesPath: treatedMessagesURL.path, value: map)
        NSLog("[Talk9-Push]   decrypt result=%@", String(describing: result))
        // [TALK9] R3: OpenDHT re-announces values (replication, storage
        // maintenance), so the same value id can arrive in pushes minutes
        // apart — far outside the burst window. A value we already acted on
        // must never ring CallKit or produce a banner a second time.
        let valueId = map["id"] as? String ?? ""
        // [TALK9-DIAG] Counterpart to the SKIP line above: what the value the
        // server DID name actually decrypted to. `unknown` here next to a
        // decodable SKIP above is the smoking gun.
        Self.diagAppend("PROCESS id=\(valueId) result=\(result)")
        switch result {
        case .call(let peerId, let hasVideo):
            guard self.claimUnseenValue(valueId) else {
                log("[Talk9-Notif] call value \(valueId.prefix(12)) already handled by an earlier push — suppressing")
                break
            }
            // [TALK9] Drop calls from unknown peers when the account disallows
            // them (DHT.PublicInCalls=false). Leaving decryptYieldedRealMessage
            // false routes finish() to its SUPPRESS branch so nothing is shown.
            guard self.shouldAcceptIncomingCall(peerId: peerId) else {
                log("[Talk9-Notif] call from \(peerId.prefix(16)): account rejects unknown callers and peer is not a contact — suppressing")
                break
            }
            self.decryptYieldedRealMessage = true
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
            // No sender ID — nothing useful to show for THIS value. Skip it, but
            // do NOT finish() here: the HTTP stream may carry several values
            // (OpenDHT replication) and a later one can be the real message. An
            // early finish() consumes contentHandler with a suppressed card and
            // the real banner would be silently dropped.
            guard !peerId.trimmingCharacters(in: .whitespaces).isEmpty else {
                log("[Talk9-Notif] gitMessage: peerId is empty — skipping this value")
                break
            }
            guard self.claimUnseenValue(valueId) else {
                log("[Talk9-Notif] gitMessage value \(valueId.prefix(12)) already handled by an earlier push — suppressing")
                break
            }
            // [TALK9] Unknown-sender filtering. When the account rejects unknown
            // peers (DHT.PublicInCalls=false), suppress ONLY brand-new
            // unsolicited 1:1 requests from strangers. shouldAcceptIncomingMessage
            // always allows any conversation that already exists locally (groups
            // AND accepted 1:1s), so a group message from a non-contact member is
            // never silenced — preserving the blacklist-only philosophy below.
            if !self.shouldAcceptIncomingMessage(convId: convId, peerId: peerId) {
                log("[Talk9-Notif] gitMessage: sender \(peerId.prefix(16)) is not a contact and conv '\(convId.prefix(8))' has no local history — account rejects unknown senders — suppressing")
                break
            }
            // [TALK9] Phantom-notification suppression — BLACKLIST ONLY.
            //
            // Original design used a whitelist (active conversations) + contacts
            // snapshot, but those produced over-suppression in production:
            // sceneDidBecomeActive can run before the daemon finishes loading
            // every conversation, leaving the snapshot PARTIAL — real messages
            // for convs not yet enumerated would get silently dropped for ~10min
            // until conversationReady callbacks catch up.
            //
            // Pure-blacklist (only suppress what we KNOW was explicitly left) is
            // safer: it never false-positives a real message. The cost is that
            // phantom pushes from a peer where we have no left-record may slip
            // through. Acceptable trade — visible phantom >>> missed real msg.
            if !convId.isEmpty,
               let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier) {
                let leftSet = defaults.stringArray(forKey: Constants.talk9LeftConversationsKey) ?? []
                if leftSet.contains(convId) {
                    log("[Talk9-Notif] gitMessage: convId='\(convId.prefix(8))' is in the left-suppression set — suppressing")
                    break // routes to finish()'s !decryptYieldedRealMessage SUPPRESS branch
                }
            }
            // [TALK9] Per-conversation banner collapse (R3: replace, never
            // suppress — suppressing would drop a genuinely new message, which
            // is how the "voice notification never came" report happened).
            // The first push for a conversation rings; every later one replaces
            // the standing banner and stays SILENT, however far apart they are.
            //
            // The 12 s window this used to enforce was calibrated for one voice
            // message fanning out into ~4 alerts within ~9 s. It does not cover
            // the dominant case: an undelivered message makes the SENDER retry
            // the connection every 30-80 s for as long as the recipient stays
            // offline, each retry carrying a brand-new PeerConnectionRequest id,
            // so the value-id claim above misses them too and every retry used
            // to ring. Ringing again is pure noise anyway — while the app is
            // dead the body is always the generic fallback, so a second card
            // carries nothing the first one did not.
            //
            // Talk9BannerDedup.reset() clears the markers when the app reaches
            // the foreground, so the next genuinely new message rings again.
            let predecessor = burstPredecessor(convId: convId, peerId: peerId)
            if let predecessorId = predecessor.id {
                let kind = predecessor.withinBurst ? "burst follower" : "sender retry"
                log("[Talk9-Notif] gitMessage: \(kind) for convId='\(convId.prefix(8))' peerId='\(peerId.prefix(16))' — replacing banner \(predecessorId.prefix(12)), silent")
                self.replacePreviousBannerId = predecessorId
                self.bestAttemptContent.sound = nil
            }
            self.decryptYieldedRealMessage = true
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
                // Only set title if a real name exists — do NOT fall back to peerId hash.
                // If title stays empty, finish() will suppress the notification entirely.
                if let realName = localName {
                    self.bestAttemptContent.title = realName
                }
                log("[Talk9-Notif] vCard name: \(localName ?? "none — waiting for nameserver")")
                // 2. Try name server lookup (async, may find registered username)
                self.lookupSenderName(peerId: peerId)
            }
            // peerId empty → title stays empty → finish() suppresses
            self.handleGitMessage(convId: convId, loadAll: convId.isEmpty) // async
        case .conversationRequest(let convId, let peerId):
            // [TALK9] R4: conversation invite (TrustRequest, confirm=false).
            // These used to come through as .gitMessage with an EMPTY peerId,
            // hit the empty-peer skip and vanish — new invites AND re-invites
            // produced no banner while the app was dead (the upstream invite
            // notification path died with the in-NSE daemon).
            guard self.claimUnseenValue(valueId) else {
                log("[Talk9-Notif] invite value \(valueId.prefix(12)) already handled by an earlier push — suppressing")
                break
            }
            // Same stranger policy as messages: contacts' (re-)invites always
            // pass; a stranger's invite is hidden when the account rejects
            // unknown senders. peerId can be a device id (inviter's cert not
            // cached yet) or empty — fail open in those cases.
            if !peerId.isEmpty && !self.shouldAcceptIncomingMessage(convId: convId, peerId: peerId) {
                log("[Talk9-Notif] invite from \(peerId.prefix(16)): account rejects unknown senders — suppressing")
                break
            }
            // Deliberately NOT consulting the left-conversations blacklist:
            // an explicit re-invite to a conversation the user left must
            // surface again (leave → re-invite flow).
            self.decryptYieldedRealMessage = true
            self.bestAttemptContent.userInfo = [
                Constants.NotificationUserInfoKeys.accountID.rawValue: self.accountId,
                Constants.NotificationUserInfoKeys.participantID.rawValue: peerId,
                Constants.NotificationUserInfoKeys.conversationID.rawValue: convId
            ]
            self.bestAttemptContent.body = NSLocalizedString(
                "notifications.conversationInvite",
                value: "Invitation received",
                comment: "Notification body for an incoming conversation invitation")
            // Pre-set a non-empty title so the generic FALLBACK branch (which
            // would overwrite the body with "New message") never triggers; a
            // resolved vCard or nameserver name upgrades it when available.
            self.bestAttemptContent.title = "Talk9"
            if !peerId.isEmpty {
                if let realName = self.contactProfileName(accountId: self.accountId, contactId: peerId) {
                    self.bestAttemptContent.title = realName
                } else {
                    self.lookupSenderName(peerId: peerId)
                }
            }
        case .clone:
            self.decryptYieldedRealMessage = true
            // Should start daemon and wait until clone completed
            self.taskPropertyQueue.sync { self.waitForCloning = true }
            self.handleGitMessage(convId: "", loadAll: false) // async
        case .unknown:
            // Daemon could not classify this DHT value (returns nil or unknown type).
            // Likely a non-message event (typing/receipt/sync) or already-consumed
            // message. decryptYieldedRealMessage stays false → finish() will suppress.
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

        // [TALK9] B1: read the cache synchronously. The previous 2 s asyncAfter was a
        // guaranteed no-op — three independent reasons, all verified in-tree. If you
        // are ever tempted to reinstate a wait here, disprove all three first:
        //
        //   1. Reaching handleGitMessage implies appIsActive() == false: the
        //      app-active branch of processNotificationRequest returns long before
        //      this point. The main app process is therefore dead.
        //   2. `talk9_last_msg_*` has exactly ONE writer — the main app daemon
        //      (ConversationsManager). Neither the NSE nor the share extension ever
        //      writes it. Dead app => nobody can write during the wait.
        //   3. freshThreshold is `extensionStartTime - 2.0`, i.e. only entries
        //      written BEFORE this instance started are accepted. Anything a wait
        //      could catch would be rejected by the freshness check anyway.
        //
        // => the value read at t+2s is byte-identical to the one read at t+0.
        // Cost of the removed wait: every banner delayed 2 s, and during a burst
        // (one voice message = ~4 pushes = 4 parallel NSE processes, see
        // NOTIFICATIONS.md §2.1) four processes each burned 2 s of the 30 s budget
        // and held their 24 MB memory allowance for nothing.
        guard !pendingSenderId.isEmpty,
              let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else { return }
        // Only accept cache entries written within 2 seconds before this extension
        // instance started (covers clock skew / daemon-faster-than-extension races).
        // The old 10s grace was too large: it would pick up already-read messages if
        // the user received one within the preceding 10s and then a new push arrived.
        let freshThreshold = extensionStartTime - 2.0
        var cachedBody: String?

        func freshBody(from entry: [AnyHashable: Any]?) -> String? {
            guard let entry = entry,
                  let body = entry["body"] as? String, !body.isEmpty,
                  let ts = entry["ts"] as? TimeInterval,
                  ts >= freshThreshold else { return nil }
            return body
        }

        // 1. Try per-conversation key (convId present in push payload)
        if !pendingConvId.isEmpty {
            let convKey = Constants.talk9LastMessageKeyPrefix + accountId + "_" + pendingConvId
            if let body = freshBody(from: defaults.dictionary(forKey: convKey)) {
                cachedBody = body
                log("[Talk9-Notif] cache: fresh conv key '\(body.prefix(40))'")
            }
        }
        // 2. Fall back to per-sender key (convId empty or conv key missed)
        if cachedBody == nil {
            let senderKey = Constants.talk9LastMessageKeyPrefix + "sender_" + accountId + "_" + pendingSenderId
            if let body = freshBody(from: defaults.dictionary(forKey: senderKey)) {
                cachedBody = body
                log("[Talk9-Notif] cache: fresh sender key '\(body.prefix(40))'")
            }
        }
        if let body = cachedBody {
            bestAttemptContent.body = body
        } else {
            log("[Talk9-Notif] cache: miss or stale — showing 'New message'")
        }
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
        // [TALK9] Idempotence: only the first caller wins (didReceive Task vs
        // serviceExtensionTimeWillExpire race). A second pass would re-deliver
        // contentHandler and re-run the whole cleanup/removal machinery.
        guard self.didFinish.compareExchange(expected: false,
                                             desired: true,
                                             ordering: .relaxed).exchanged else {
            return
        }
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
                self.didPresentCall = true
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
            if didPresentCall {
                // [TALK9] Call handed to CallKit (reportNewIncomingVoIPPushPayload) —
                // it presents the full-screen call UI. Delivering bestAttemptContent
                // here would add a stray "Talk9 / New message" placeholder banner
                // (bestAttemptContent starts as a copy of the server's APNs alert).
                deliverSuppressed(contentHandler, reason: "call handed to CallKit, dropping placeholder banner")
                return
            } else if didPresentLocalNotification {
                // [TALK9] D1: the content was already shown as a local
                // notification (UNUserNotificationCenter.add). Falling through
                // to contentHandler would deliver the SAME title/body again —
                // one message, two banners. Suppress the remote copy instead.
                deliverSuppressed(contentHandler, reason: "content already shown as local notification")
                return
            } else if didStartDaemon {
                deliverSuppressed(contentHandler, reason: "daemon ran, already treated by another instance")
                return
            } else if shouldSuppressCompletely {
                // Resubscribe or app-active — must show nothing at all
                deliverSuppressed(contentHandler, reason: "resubscribe / app active")
                return
            } else if !decryptYieldedRealMessage {
                // Non-message DHT event (typing/receipt/sync) or already-consumed message.
                // Server cannot filter (pt field empty in OpenDHT push payloads).
                deliverSuppressed(contentHandler, reason: "decrypt yielded no real message (non-message DHT event)")
                return
            } else if bestAttemptContent.title.trimmingCharacters(in: .whitespaces).isEmpty {
                // Extension ran but couldn't decrypt or resolve sender name.
                // Show a generic notification so the user knows there's a new message —
                // they can tap to open the app and see the real content in chat.
                bestAttemptContent.title = "Talk9"
                bestAttemptContent.body = "New message"
                NSLog("[Talk9-Push] ⚠ FALLBACK — generic 'New message' (decrypt failed)")
            } else {
                // Has title (real sender name OR fallback "New message" from APNs)
                NSLog("[Talk9-Push] ✓ SHOW  title='%@' body='%@'",
                      bestAttemptContent.title, String(bestAttemptContent.body.prefix(60)))
            }
            // Tag real-message banners with a per-conversation thread so iOS
            // groups them by chat on the lock screen, while staying outside the
            // "talk9.suppressed" namespace the cleanup paths filter on.
            let convThread = (bestAttemptContent.userInfo[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String) ?? ""
            self.bestAttemptContent.threadIdentifier = convThread.isEmpty ? "talk9.real" : "talk9.real." + convThread
            // Take advantage of this real-message delivery to sweep any orphaned
            // suppressed empty cards from previous pushes whose async cleanup never
            // completed. Cheap insurance against accumulation on the lock screen.
            removeOldSuppressedNotifications()
            // [TALK9] R3 burst collapse: this banner supersedes the burst
            // predecessor — pull the old card so the burst never stacks.
            if let predecessorId = replacePreviousBannerId {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [predecessorId])
            }
            contentHandler(self.bestAttemptContent)
        }
        NSLog("[Talk9-Push] ◀ finish done id=%@", requestIdentifier)
    }

    // [TALK9] R5 root-fix switch. Flip to true ONLY after Apple grants
    // com.apple.developer.usernotifications.filtering for
    // m.talk.talk9.jamiNotificationExtension AND the key has been added to both
    // NotificationService-*.entitlements files — see FILTERING_ENTITLEMENT.md.
    // With the entitlement, delivering empty content makes iOS drop the push with
    // no visible card at all. WITHOUT the entitlement the exact same call falls
    // back to the raw APNs placeholder banner — flipping this early is WORSE
    // than the legacy suppressed-card machinery.
    private static let filteringEntitlementGranted = false

    /// [TALK9] Single exit for every suppress path in finish().
    /// Entitled build: empty content → iOS shows nothing, no cleanup needed.
    /// Legacy build: minimal "talk9.suppressed" card plus the removal machinery —
    /// immediate polling removal (~400ms so the card barely appears), a 5 s
    /// auto-remove fallback in case iOS reaps the NSE first, and a handoff to the
    /// main app (scheduleRemoval) whose next activation sweeps survivors.
    private func deliverSuppressed(_ contentHandler: (UNNotificationContent) -> Void, reason: String) {
        NSLog("[Talk9-Push] ✗ SUPPRESS — %@", reason)
        if Self.filteringEntitlementGranted {
            contentHandler(UNMutableNotificationContent())
            return
        }
        removeOldSuppressedNotifications()
        contentHandler(makeSuppressedContent())
        scheduleRemoval(identifier: requestIdentifier)
        aggressiveImmediateRemoval(identifier: requestIdentifier)
        scheduleAutoRemove(identifier: requestIdentifier, after: 5.0)
    }

    /// Builds the minimal-visibility content used by all suppress paths.
    /// Single-space title prevents iOS from falling back to the original APNs alert.
    /// Passive interruption + zero relevance + shared threadIdentifier collapse
    /// repeated suppressed notifications into a single group in the notification center.
    /// Explicit sound=nil and badge=0 belt-and-suspenders the silencing in case
    /// .passive isn't respected on a particular iOS version / settings combo.
    private func makeSuppressedContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = " "
        content.body = ""
        content.threadIdentifier = "talk9.suppressed"
        content.sound = nil
        content.badge = 0
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
            content.relevanceScore = 0
        }
        return content
    }

    /// Removes any previously-delivered suppressed notifications before a new one
    /// is shown. threadIdentifier alone groups but does NOT replace — iOS keeps each
    /// card individually on the lock screen. Explicitly removing the older ones
    /// ensures only the latest empty card remains visible.
    ///
    /// `removeDeliveredNotifications` is async with no completion handler, so we
    /// block briefly after issuing the request to give iOS time to actually process
    /// the removal before the NSE process is potentially terminated.
    private func removeOldSuppressedNotifications() {
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let oldIds = notifications
                .filter { $0.request.content.threadIdentifier == "talk9.suppressed" }
                .map { $0.request.identifier }
            if !oldIds.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: oldIds)
                // Best-effort: let iOS start processing the async removal before
                // the NSE is reaped after contentHandler returns.
                Thread.sleep(forTimeInterval: 0.3)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }

    /// Best-effort: schedule the just-delivered suppressed notification to be removed
    /// after a short delay. Not guaranteed to fire — iOS may terminate the extension
    /// before the timer elapses. When it does fire, the empty card disappears from
    /// the lock screen and notification center, giving a "self-cleanup" feel.
    ///
    /// Defensive: only removes if the notification actually has
    /// `threadIdentifier == "talk9.suppressed"`. If iOS happens to deliver an
    /// unrelated (real) notification under the same identifier in the meantime,
    /// we won't accidentally delete it.
    private func scheduleAutoRemove(identifier: String, after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let matches = notifications
                    .filter { $0.request.identifier == identifier &&
                              $0.request.content.threadIdentifier == "talk9.suppressed" }
                    .map { $0.request.identifier }
                if !matches.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matches)
                }
            }
        }
    }

    /// [TALK9] Aggressively remove a just-delivered suppressed notification
    /// while the NSE process is still alive. Polls iOS up to `maxAttempts`
    /// times because the time between contentHandler being called and iOS
    /// actually inserting the notification into the delivered list varies —
    /// a fixed 100ms wait was too short in production (empty cards persisted
    /// for ~6 min when the NSE was reaped before the single one-shot check).
    ///
    /// Total worst-case NSE time spent here: ~1.4s (well within the 30s budget).
    /// On success, exits as soon as iOS confirms delivery + removal.
    ///
    /// Defensive: same threadIdentifier check as scheduleAutoRemove — never
    /// touches a notification that isn't ours.
    private func aggressiveImmediateRemoval(identifier: String) {
        let maxAttempts = 6
        let perAttemptWait: TimeInterval = 0.2
        for attempt in 0..<maxAttempts {
            Thread.sleep(forTimeInterval: perAttemptWait)
            var removed = false
            let semaphore = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let matches = notifications
                    .filter { $0.request.identifier == identifier &&
                              $0.request.content.threadIdentifier == "talk9.suppressed" }
                    .map { $0.request.identifier }
                if !matches.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matches)
                    removed = true
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 0.5)
            if removed {
                NSLog("[Talk9-Push] aggressiveImmediateRemoval succeeded on attempt %d", attempt + 1)
                // Give iOS a beat to actually process the removal before NSE is reaped.
                Thread.sleep(forTimeInterval: 0.2)
                return
            }
        }
        NSLog("[Talk9-Push] aggressiveImmediateRemoval exhausted %d attempts — relying on scheduleAutoRemove + app-launch sweep", maxAttempts)
    }

    /// Stores an APNs notification identifier in shared UserDefaults so the main app
    /// can call removeDeliveredNotifications when it becomes active.
    /// The extension process may be killed before async removal completes, so we
    /// delegate the actual removal to the main app which has a stable lifecycle.
    private func scheduleRemoval(identifier: String) {
        guard let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else { return }
        var pending = defaults.stringArray(forKey: Constants.pendingNotificationRemovalKey) ?? []
        if !pending.contains(identifier) {
            pending.append(identifier)
        }
        defaults.set(pending, forKey: Constants.pendingNotificationRemovalKey)
    }

    /// [TALK9] Atomic check-and-swap for the burst-collapse gate (R3: replace,
    /// don't suppress). Returns nil when this push starts a new burst, or the
    /// PREVIOUS push's request identifier when it is a follower within
    /// `talk9DedupWindowSeconds` — the caller then replaces that banner
    /// instead of stacking (old behavior: suppress, which could drop a real
    /// second message). The marker file's CONTENT is the latest banner's
    /// request id; its mtime is the window clock.
    ///
    /// Concurrency: iOS runs several NSE instances in PARALLEL PROCESSES (one
    /// per push of the burst). open(O_CREAT|O_EXCL) on a marker file in the
    /// App Group container is atomic across processes:
    ///   - creation succeeds → burst head: store own id, show with sound
    ///   - marker fresh → follower: swap own id in, replace the predecessor
    ///   - marker expired/unreadable → new burst head: swap own id in, show.
    /// Two parallel followers can both read the same predecessor and briefly
    /// leave 2 banners (last marker write wins; the next follower removes one
    /// of them). Worst case is a transient 2-stack — never 4, never a lost
    /// message.
    private func burstPredecessor(convId: String, peerId: String) -> (id: String?, withinBurst: Bool) {
        guard !peerId.isEmpty, let dir = Self.dedupMarkerDirectory() else {
            return (nil, false)
        }
        // convId/peerId are hex identifiers — safe to use in a filename.
        let marker = dir.appendingPathComponent("\(convId)_\(peerId)")
        let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 {
            if let data = requestIdentifier.data(using: .utf8) {
                data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            }
            close(fd)
            Self.pruneDedupMarkers(in: dir)
            return (nil, false)
        }
        let isFresh: Bool
        if let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < Constants.talk9DedupWindowSeconds {
            isFresh = true
        } else {
            isFresh = false
        }
        let predecessorId = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Take over the marker: our banner is now the burst's latest (the
        // atomic rewrite also refreshes mtime, restarting the window).
        try? requestIdentifier.data(using: .utf8)?.write(to: marker, options: .atomic)
        // [TALK9] The predecessor is returned whether or not the window is
        // fresh: a stale marker means the previous banner is STILL the only one
        // this conversation should own, not that a new one may stack on top.
        // isFresh now only answers "is this a burst follower", i.e. stay silent.
        guard let predecessorId = predecessorId, !predecessorId.isEmpty else {
            return (nil, isFresh)
        }
        return (predecessorId, isFresh)
    }

    /// [TALK9] R3: cross-process claim of a DHT value id — returns true exactly
    /// once per value; O_CREAT|O_EXCL marker creation is the claim. Value ids
    /// never legitimately recur after the value expires (minutes), so bare
    /// marker existence means duplicate — no freshness window needed. Fails
    /// open: better a duplicate banner than a lost message.
    private func claimUnseenValue(_ valueId: String) -> Bool {
        guard !valueId.isEmpty, let dir = Self.seenValueDirectory() else {
            return true
        }
        let marker = dir.appendingPathComponent(valueId)
        let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 {
            close(fd)
            Self.pruneSeenValueMarkers(in: dir)
            return true
        }
        return false
    }

    private static func seenValueDirectory() -> URL? {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupIdentifier) else {
            return nil
        }
        let dir = container.appendingPathComponent("Library/Caches/talk9-push-seen",
                                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Same housekeeping as pruneDedupMarkers: DHT values expire within
    /// minutes, so an hour-old seen-marker can never match a live value again.
    private static func pruneSeenValueMarkers(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        guard let files = try? FileManager.default
                .contentsOfDirectory(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Shared with the main app, which clears these markers on foreground
    /// (Talk9BannerDedup.reset) to restore every conversation's right to ring.
    // MARK: - [TALK9-DIAG] Temporary decrypt diagnostics
    //
    // Why this exists: a push arrived, the NSE ran, the DHT stream returned two
    // values, the one the server named in `ids` threw inside decrypt(), and the
    // other one was skipped without ever being tried — so the user got nothing.
    // These helpers record what every value in the stream looks like and whether
    // it could have been decrypted, so the choice the `ids` field makes can be
    // checked against reality.
    //
    // Device logs are not persisted on iOS, so this also appends to a file in
    // the App Group: reproduce whenever, pull the file afterwards.
    //
    // DELETE the whole section, its two call sites, and the %{public}s changes
    // in Adapter.mm once the root cause is known.
    static func diagAppend(_ line: String) {
        guard let caches = Constants.cachesPath else { return }
        let file = caches.appendingPathComponent("talk9-diag.log")
        // Cheap cap so a long-running reproduction cannot fill the container.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        // O_APPEND makes each write atomic across the parallel NSE processes a
        // burst spawns — no locking, no interleaved half-lines.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        _ = entry.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    private static func dedupMarkerDirectory() -> URL? {
        return Talk9BannerDedup.directory
    }

    /// Housekeeping: markers older than an hour are useless — remove them so
    /// the directory doesn't grow unbounded over days of pushes.
    private static func pruneDedupMarkers(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        guard let files = try? FileManager.default
                .contentsOfDirectory(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
        // [TALK9] R2: file-per-push queue (see Talk9PushQueue in Constants.swift).
        // The previous UserDefaults array was read-modify-write with no
        // cross-process lock — parallel NSE instances (one per push of a burst)
        // racing the app's read→clear drain silently dropped entries.
        Talk9PushQueue.enqueue(data)
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
    // [TALK9] R9: name lookups race the NSE's 25 s budget. URLSession.shared's
    // default 60 s timeout meant a black-holed name server held the dispatch
    // group until the group wait expired — every banner then arrived ~25 s
    // late with the generic title. 8 s caps the damage; vCard hits (the common
    // case) never touch the network at all.
    private static let nameLookupSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

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
        let task = Self.nameLookupSession.dataTask(with: url) {[weak self](data, response, _) in
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
                    guard let name = name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                        log("[Talk9-Notif] lookupCompleted: no name resolved for \(address.prefix(8)) — suppressing")
                        continue
                    }
                    notification.content.title = name
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
        Self.nameLookupSession.dataTask(with: url) { [weak self] data, response, error in
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

    // MARK: - [TALK9] Unknown-peer filtering

    /// Whether `peerId` is one of this account's active (non-banned) contacts.
    private func isKnownContact(_ peerId: String, in contacts: [[String: String]]) -> Bool {
        let target = peerId.normalizedJamiId
        return contacts.contains { ($0["id"]?.normalizedJamiId) == target }
    }

    /// Whether the local conversation store already has history for `convId`.
    /// True for any established conversation (group OR accepted 1:1); false for
    /// a brand-new unsolicited request the daemon has not cloned yet. Fails
    /// open (returns true) if the documents path is unavailable.
    private func conversationExistsOnDisk(convId: String) -> Bool {
        guard let documents = Constants.documentsPath else { return true }
        let base = documents.appendingPathComponent(self.accountId)
        let fileManager = FileManager.default
        let repo = base.appendingPathComponent("conversations").appendingPathComponent(convId)
        let data = base.appendingPathComponent("conversation_data").appendingPathComponent(convId)
        return fileManager.fileExists(atPath: repo.path) || fileManager.fileExists(atPath: data.path)
    }

    /// Whether an incoming CALL from `peerId` should be shown. Mirrors the
    /// daemon's "allow calls from unknown contacts" account flag: when enabled
    /// everything is accepted, otherwise only known contacts are.
    private func shouldAcceptIncomingCall(peerId: String) -> Bool {
        if self.adapterService.allowsIncomingCallsFromUnknown(accountId: self.accountId) { return true }
        let contacts = self.adapterService.getContacts(accountId: self.accountId)
        return self.isKnownContact(peerId, in: contacts)
    }

    /// Whether an incoming MESSAGE should be shown. Group-safe: only suppresses
    /// brand-new unsolicited 1:1 requests from non-contacts. Established
    /// conversations (groups and accepted 1:1s) are always accepted, so group
    /// messages from non-contact members are never silenced.
    private func shouldAcceptIncomingMessage(convId: String, peerId: String) -> Bool {
        if self.adapterService.allowsIncomingCallsFromUnknown(accountId: self.accountId) { return true }
        let contacts = self.adapterService.getContacts(accountId: self.accountId)
        if self.isKnownContact(peerId, in: contacts) { return true }
        if !convId.isEmpty && self.conversationExistsOnDisk(convId: convId) { return true }
        return false
    }
}

private extension String {
    /// Normalizes a Jami id/uri for comparison: strips the `ring:`/`jami:`
    /// scheme prefix and lowercases (daemon contact ids are lowercase hex).
    var normalizedJamiId: String {
        return self.replacingOccurrences(of: "ring:", with: "")
            .replacingOccurrences(of: "jami:", with: "")
            .lowercased()
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
        // Do NOT fall back to config.from (peerId hash) — leave title empty so
        // presentLocalNotification's guard suppresses it until a real name is resolved.
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
        // No title means we couldn't resolve the sender — suppress the notification.
        guard !content.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            log("[Talk9-Notif] presentLocalNotification: suppressing — empty title")
            self.taskPropertyQueue.sync { self.itemsToPresent -= 1 }
            self.verifyTasksStatus()
            return
        }
        // Keep bestAttemptContent in sync so the contentHandler fallback also shows
        // the real sender name and message instead of the APNs placeholder "hello".
        self.bestAttemptContent.title = content.title
        self.bestAttemptContent.body = content.body
        if let attachment = content.attachments.first {
            self.bestAttemptContent.attachments = [attachment]
        }
        self.didPresentLocalNotification = true
        setNotificationCount(notification: content)
        // Per-conversation thread: groups by chat on the lock screen and stays
        // outside the "talk9.suppressed" namespace the cleanup paths filter on.
        let convThread = (content.userInfo[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String) ?? ""
        content.threadIdentifier = convThread.isEmpty ? "talk9.real" : "talk9.real." + convThread
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
