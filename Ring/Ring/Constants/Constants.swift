/*
 *  Copyright (C) 2022-2025 Savoir-faire Linux Inc.
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

let contributorsDevelopers: String = """
Abhishek Ojha
Adrien Béraud
Alassane Yattara
Albert Babí
Alexander Lussier-Cullen
Alexandr Sergheev
Alexandre Eberhardt
Alexandre Lision
Alexandre Savard
Alexandre Viau
Aline Bonnet
Aline Gondim Santos
Alireza Toghiani
Amin Bandali
AmirHossein Naghshzan
Amna Snene
Andreas Hatziiliou
Andreas Traczyk
Anthony Léonard
Brando Tovar
Capucine Berthet
Charles-Francis Damedey
Christophe Villemer
Cyrille Béraud
Eden Abitbol
Édric Milaret
Éloi Bail
Emma Falkiewitz
Emmanuel Lepage-Vallée
Emmanuel Milou
Eric Bjarstal
Fadi Shehadeh
Félix Boucher
Franck Laurent
François-Simon Fauteux-Chapleau
Frédéric Guimont
Guillaume Heller
Guillaume Roguez
Hadrien De Sousa
Hugo Lefeuvre
Hussein Abdallah
Ilyas Erdogan
Io Daza-Dillon
Jérôme Lamy
Julien Grossholtz
Julien Robert
Kateryna Kostiuk
Kessler DuPont-Teevin
Lanius-collaris
Larbi Gharib
Léo Banno-Cloutier
Léopold Chappuis
Liam Courdoson
Loïc Siret
Louis Maillard
Mathéo Joseph
Maxim Cournoyer
Michel Schmit
Mingrui Zhang
Mohamed Amine Younes Bouacida
Mohamed Chibani
Nghia Dam
Nicolas Jäger
Nicolas Reynaud
Nicolas Vengeon
Olivier Gregoire
Olivier Soldano
Page Magnier-Slimani
Patrick Keroulas
Pavan Koushik Nellore
Peymane Marandi
Philippe Gorley
Pierre Duchemin
Pierre Lespagnol
Pierre Nicolas
Raphaël Brulé
Rawaha El Houssayni
Rayan Osseiran
Romain Bertozzi
Saher Azer
Samuel Kayode
Sébastien Blin
Seva Ivanov
Silbino Gonçalves Matado
Simon Désaulniers
Simon Zeni
Stepan Salenikovich
Thibault Wittemberg
Thomas Ballasi
Trevor Tabah
Vitalii Nikitchyn
Vsevolod Ivanov
Xavier Jouslin de Noray
Yang Wang
Ziwei Wang
"""

let contributorsMedia: String = """
Charlotte Hoffman
Marianne Forget
"""

let contributorsCommunityManagement: String = """
Dorina Mosku
Cabrel Tambue
Loïc Bogino
"""

let specialThanks: String = """
Anna
Elys
VeroJeanLuc
"""

// [TALK9] R2: cross-process-safe queue for push payloads awaiting a daemon.
// The NSE writes one uniquely-named file per push; the main app and the share
// extension drain the directory. Replaces the read-modify-write array under
// Constants.notificationData in shared UserDefaults, which lost entries under
// concurrency: a drainer loads [A], a parallel NSE instance writes [A,B], the
// drainer writes [] back — B was never fed to any daemon. A burst (one voice
// message = 4 pushes = 4 parallel NSE processes) hit that window reliably.
enum Talk9PushQueue {
    private static var directory: URL? {
        guard let caches = Constants.cachesPath else { return nil }
        let dir = caches.appendingPathComponent("talk9-push-queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Enqueue one push payload. Unique filename (epoch-ms + UUID) means there
    /// is no shared state to clobber; the atomic write means a drain never
    /// sees a half-written file.
    static func enqueue(_ data: [String: String]) {
        guard let dir = directory,
              let payload = try? JSONSerialization.data(withJSONObject: data) else { return }
        let name = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString)"
        try? payload.write(to: dir.appendingPathComponent(name), options: .atomic)
        prune(dir)
    }

    /// Remove and return all queued payloads, oldest first. Also drains any
    /// leftovers from the legacy UserDefaults array (entries written by a
    /// pre-update NSE survive the app update). Concurrent drainers (main app
    /// vs share extension) may race: deletion is the claim, so each entry is
    /// consumed at most once.
    static func drain() -> [[String: String]] {
        var entries = [[String: String]]()
        if let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier),
           let legacy = defaults.object(forKey: Constants.notificationData) as? [[String: String]],
           !legacy.isEmpty {
            defaults.set([[String: String]](), forKey: Constants.notificationData)
            entries.append(contentsOf: legacy)
        }
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return entries
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Only touch files matching our "<epoch-ms>_<uuid>" naming — skips
            // Foundation's atomic-write temp files and filesystem noise.
            guard let prefix = file.lastPathComponent.split(separator: "_").first,
                  Int64(prefix) != nil,
                  let payload = try? Data(contentsOf: file) else { continue }
            do { try FileManager.default.removeItem(at: file) } catch { continue }
            if let dict = (try? JSONSerialization.jsonObject(with: payload)) as? [String: String] {
                entries.append(dict)
            }
        }
        return entries
    }

    /// Queue files older than a day reference DHT values that expired long
    /// ago; drop them so the directory cannot grow unbounded while the app
    /// stays unopened.
    private static func prune(_ dir: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// [TALK9] Per-conversation banner dedup markers, shared so the main app can
// reset them. The NSE writes one marker per (convId, peerId): the file content
// is the latest banner's request id, its existence means "this conversation
// already has a banner up and has already rung once".
//
// The marker used to be considered stale after talk9DedupWindowSeconds, which
// let a sender's connection retries each ring as if they were new messages —
// one undelivered message produces a fresh PeerConnectionRequest (new value id)
// every 30-80 s for as long as the recipient stays offline, so neither the
// value-id claim nor the 12 s window could collapse them. The window now only
// decides whether to stay silent; the marker itself lives until the app comes
// to the foreground. See NOTIFICATIONS.md.
enum Talk9BannerDedup {
    static var directory: URL? {
        guard let caches = Constants.cachesPath else { return nil }
        let dir = caches.appendingPathComponent("talk9-push-dedup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The user is looking at the app, so every conversation earns the right to
    /// ring again. Called on foreground; a failure here only costs an extra
    /// banner sound, never a lost message.
    static func reset() {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

public class Constants: NSObject {
    @objc public static let notificationReceived = "m.talk.talk9.notificationExtension.receivedNotification" as CFString
    @objc public static let notificationAppIsActive = "m.talk.talk9.appActive" as CFString
    @objc public static let notificationShareExtensionIsActive = "m.talk.talk9.shareExtension.isActive" as CFString
    @objc public static let notificationShareExtensionResponse = "m.talk.talk9.shareExtension.response" as CFString
    @objc public static let notificationExtensionIsActive = "m.talk.talk9.notificationExtension.isActive" as CFString
    @objc public static let notificationExtensionResponse = "m.talk.talk9.notificationExtension.accountActive" as CFString
    @objc public static let notificationData = "notificationData"
    @objc public static let updatedConversations = "updatedConversations"
    @objc public static let queriedAccountId = "queriedAccountId"
    @objc public static let shareExtensionActiveAccounts = "shareExtensionActiveAccounts"
    @objc public static let appGroupIdentifier = "group.m.talk.talk9.shared"
    @objc public static let notificationsCount = "notificationsCount"
    @objc public static let appIdentifier = "m.talk.talk9"

    public static let selectedAccountID = "SELECTED_ACCOUNT_ID"
    public static let talk9RegisteredPhonePrefix = "talk9_registered_phone_"
    public static let talk9LastMessageKeyPrefix = "talk9_last_msg_"
    public static let pendingNotificationRemovalKey = "talk9_pending_notification_removal"
    // [TALK9] Set of conversation IDs the local user has left or removed.
    // Main app writes; NSE reads to suppress phantom pushes from peers whose
    // daemon hasn't yet synced the local leave commit.
    public static let talk9LeftConversationsKey = "talk9_left_conversations"
    // [TALK9] Whitelist of conversation IDs the local user currently participates
    // in. NSE suppresses any .gitMessage push whose convId is NOT in this set —
    // catches phantom pushes for convs the daemon has already cleaned up after a
    // sync, where the per-leave "left set" no longer has the convId either.
    public static let talk9ActiveConversationsKey = "talk9_active_conversations"
    // [TALK9] Snapshot of the current contacts list (Jami IDs). NSE uses this
    // to suppress phantom pushes from peers the user has explicitly deleted —
    // catches the case where daemon's push carries an empty convId (legacy/sync
    // events) so the conv-id-based check above can't fire.
    public static let talk9CurrentContactsKey = "talk9_current_contacts"
    // [TALK9] Dedup time window in seconds. Server reported voice file-transfer
    // events span ~9s and text-message chunks can spread 10+s. 12s gives a
    // safety margin without blocking a back-and-forth chat (typical typing
    // cadence is ≥15s between consecutive messages from the same person).
    public static let talk9DedupWindowSeconds: TimeInterval = 12.0

    @objc public static let documentsPath: URL? = {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?.appendingPathComponent("Documents")
    }()

    @objc public static let cachesPath: URL? = {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?.appendingPathComponent("Library").appendingPathComponent("Caches")
    }()

    @objc public static let versionNumber: String? = {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }()

    @objc public static let buildNumber: String? = {
        let dateDefault = ""
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "YYYYMMdd"
        let bundleName = Bundle.main.infoDictionary!["CFBundleName"] as? String ?? "Info.plist"
        if let infoPath = Bundle.main.path(forResource: bundleName, ofType: nil),
           let infoAttr = try? FileManager.default.attributesOfItem(atPath: infoPath),
           let infoDate = infoAttr[FileAttributeKey.creationDate] as? Date {
            return dateFormatter.string(from: infoDate)
        }
        return dateDefault
    }()

    @objc public static let fullVersion: String? = {
        if let versionNumber:String = Constants.versionNumber,
           let buildNumber = Constants.buildNumber {
            return "\(versionNumber)(\(buildNumber))"
        }
        return nil
    }()

    enum NotificationUserInfoKeys: String {
        case callID
        case name
        case messageContent
        case participantID
        case accountID
        case conversationID
        case callURI
    }

    enum NotificationCategory: String {
        case call = "CALL_CATEGORY"
    }

    enum NotificationAction: String {
        case acceptVideo = "GROUP_ACCEPT_VIDEO_ACTION"
        case acceptAudio = "GROUP_ACCEPT_AUDIO_ACTION"
    }

    enum NotificationActionIcon: String {
        case video = "video.fill"
        case audio = "phone.fill"
    }

    enum NotificationActionTitle {
        case acceptWithVideo
        case acceptWithAudio

        func toString() -> String {
            switch self {
                case .acceptWithVideo:
                    return L10n.Calls.acceptWithVideo
                case .acceptWithAudio:
                    return L10n.Calls.acceptWithAudio
            }
        }
    }
    
    public static let swarmColors: [String: String] = [
        "#E91E63": L10n.SwarmColors.vibrantPink,
        "#9C27B0": L10n.SwarmColors.purple,
        "#673AB7": L10n.SwarmColors.violet,
        "#3F51B5": L10n.SwarmColors.indigoBlue,
        "#2196F3": L10n.SwarmColors.skyBlue,
        "#00BCD4": L10n.SwarmColors.cyan,
        "#009688": L10n.SwarmColors.teal,
        "#4CAF50": L10n.SwarmColors.green,
        "#8BC34A": L10n.SwarmColors.limeGreen,
        "#9E9E9E": L10n.SwarmColors.mediumGray,
        "#CDDC39": L10n.SwarmColors.yellowGreen,
        "#FFC107": L10n.SwarmColors.amber,
        "#FF5722": L10n.SwarmColors.brightOrange,
        "#795548": L10n.SwarmColors.brown,
        "#607D8B": L10n.SwarmColors.steelBlue
    ]

    public static let maxProfileImageSize: CGFloat = 512

    enum AvatarSize: CGFloat {
        case conversation20 = 20
        case conversation30 = 30
        case medium40 = 40
        case medium45 = 45
        case medium50 = 50
        case default55 = 55
        case conversationInfo80 = 80
        case call160 = 160
        case account100 = 100
        case account60 = 60
        case account28 = 28

        var points: CGFloat { rawValue }
    }

    public static let defaultAvatarSize: CGFloat = AvatarSize.default55.points

    public static let versionName = "Euclid"
}
