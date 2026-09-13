/*
 * Copyright (C) 2017-2026 Savoir-faire Linux Inc.
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

import UIKit
import SwiftyBeaver
import RxSwift
import PushKit
import ContactsUI
import os

// swiftlint:disable identifier_name type_body_length
@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    let dBManager = DBManager(profileHepler: ProfileDataHelper(),
                              conversationHelper: ConversationDataHelper(),
                              interactionHepler: InteractionDataHelper(),
                              dbConnections: DBContainer())
    private let daemonService = DaemonService(dRingAdaptor: DRingAdapter())
    private let nameService = NameService(withNameRegistrationAdapter: NameRegistrationAdapter())
    private let presenceService = PresenceService(withPresenceAdapter: PresenceAdapter())
    private let videoService = VideoService(withVideoAdapter: VideoAdapter())
    private let audioService = AudioService(withAudioAdapter: AudioAdapter())
    private let systemService = SystemService(withSystemAdapter: SystemAdapter())
    private let networkService = NetworkService()
    private let callsProvider: CallsProviderService = CallsProviderService(provider: CXProvider(configuration: CallsHelpers.providerConfiguration()), controller: CXCallController())
    private var conversationManager: ConversationsManager?
    private var interactionsManager: GeneratedInteractionsManager?
    private var videoManager: VideoManager?
    private lazy var callService: CallsService = {
        CallsService(withCallsAdapter: CallsAdapter(), dbManager: self.dBManager)
    }()
    internal lazy var accountService: AccountsService = {
        AccountsService(withAccountAdapter: AccountAdapter(), dbManager: self.dBManager)
    }()
    private lazy var contactsService: ContactsService = {
        ContactsService(withContactsAdapter: ContactsAdapter(), dbManager: self.dBManager)
    }()
    private lazy var profileService: ProfilesService = {
        ProfilesService(withProfilesAdapter: ProfilesAdapter(), dbManager: self.dBManager)
    }()
    private lazy var dataTransferService: DataTransferService = {
        DataTransferService(withDataTransferAdapter: DataTransferAdapter(),
                            dbManager: self.dBManager)
    }()
    private lazy var conversationsService: ConversationsService = {
        ConversationsService(withConversationsAdapter: ConversationsAdapter(), dbManager: self.dBManager)
    }()
    private lazy var locationSharingService: LocationSharingService = {
        LocationSharingService(dbManager: self.dBManager)
    }()
    private lazy var requestsService: RequestsService = {
        RequestsService(withRequestsAdapter: RequestsAdapter(), dbManager: self.dBManager)
    }()

    private let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    /*
     When the app is in the background, but the call screen is present, notifications
     should be handled by Jami.app and not by the notification extension.
     */
    private var presentingCallScreen = false

    // MARK: - Connection Retry Timer
    // Fires every 5 minutes to keep TURN relay allocations alive and re-bootstrap
    // swarm peer connections that may have gone idle.
    private var connectivityTimer: Timer?

    // MARK: - Stuck-Sending Watchdog (Trigger 4)
    // Keyed by messageId. If a message stays in "sending" for > 90 s, we auto-ReReg.
    private var sendingWatchdogTimers: [String: Timer] = [:]

    lazy var injectionBag: InjectionBag = {
        return InjectionBag(withDaemonService: self.daemonService,
                            withAccountService: self.accountService,
                            withNameService: self.nameService,
                            withConversationService: self.conversationsService,
                            withContactsService: self.contactsService,
                            withPresenceService: self.presenceService,
                            withNetworkService: self.networkService,
                            withCallService: self.callService,
                            withVideoService: self.videoService,
                            withAudioService: self.audioService,
                            withDataTransferService: self.dataTransferService,
                            withProfileService: self.profileService,
                            withCallsProvider: self.callsProvider,
                            withLocationSharingService: self.locationSharingService,
                            withRequestsService: self.requestsService,
                            withSystemService: self.systemService)
    }()
    private lazy var appCoordinator: AppCoordinator = {
        return AppCoordinator(injectionBag: self.injectionBag)
    }()

    // MARK: - Public Interface for SceneDelegate
    var rootViewController: UIViewController {
        return appCoordinator.rootViewController
    }

    func startAppCoordinator() {
        appCoordinator.start()
    }

    private let log = SwiftyBeaver.self

    private let disposeBag = DisposeBag()

    private let backgrounTaskQueue = DispatchQueue(label: "backgrounTaskQueue")

    // MARK: - Push handshake (NSE "is the app active?" query)
    // [TALK9] R11: answered OFF the main thread. The NSE gives the app 0.3 s;
    // the old chain (CFNotificationCenter darwin callback → NSNotification →
    // main.async → reply) needed a main run loop turn at every hop, so any
    // brief main-thread stall made the NSE treat a foreground app as dead and
    // pop a banner on top of it.
    private let handshakeQueue = DispatchQueue(label: "talk9.push.handshake", qos: .userInteractive)
    private var handshakeNotifyToken: Int32 = 0
    // Queue-confined mirror of "app is backgrounded" — applicationState is
    // main-thread-only UIKit, so the scene callbacks publish changes here
    // instead of the handshake reading UIKit off the main thread. Starts true:
    // until the first willEnterForeground the NSE owns every push (prewarm and
    // VoIP background launches included).
    private var appIsInBackgroundForHandshake = true

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let sceneConfig = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        sceneConfig.delegateClass = SceneDelegate.self
        return sceneConfig
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // ignore sigpipe
        typealias SigHandler = @convention(c) (Int32) -> Void
        let SIG_IGN = unsafeBitCast(OpaquePointer(bitPattern: 1), to: SigHandler.self)
        signal(SIGPIPE, SIG_IGN)
        // swiftlint:enable nesting
        UserDefaults.standard.setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        if UserDefaults.standard.value(forKey: automaticDownloadFilesKey) == nil {
            UserDefaults.standard.set(true, forKey: automaticDownloadFilesKey)
        }
        UserDefaults.standard.setValue(true, forKey: "usingGroupConatiner")
        UNUserNotificationCenter.current().delegate = self
        // initialize log format
        let console = ConsoleDestination()
        console.format = "$Dyyyy-MM-dd HH:mm:ss.SSS$d $C$L$c: $M"
        #if DEBUG
        log.addDestination(console)
        #else
        log.removeAllDestinations()
        #endif

        PreferenceManager.registerDonationsDefaults()

        self.addListenerForNotification()

        // requests permission to use the camera
        // will enumerate and add devices once permission has been granted
        self.videoService.setupInputs()

        self.audioService.connectAudioSignal()

        // Observe connectivity changes and reconnect DHT
        self.networkService.connectionStateObservable
            .skip(1)
            .subscribe(onNext: { _ in
                self.daemonService.connectivityChanged()
            })
            .disposed(by: self.disposeBag)

        // start monitoring for network changes
        self.networkService.monitorNetworkType()

        self.subscribeConversationSyncRetry()

        self.interactionsManager = GeneratedInteractionsManager(accountService: self.accountService,
                                                                requestsService: self.requestsService,
                                                                conversationService: self.conversationsService,
                                                                callService: self.callService)

        self.conversationManager = ConversationsManager(with: self.conversationsService,
                                                        accountsService: self.accountService,
                                                        nameService: self.nameService,
                                                        dataTransferService: self.dataTransferService,
                                                        callService: self.callService,
                                                        locationSharingService: self.locationSharingService, contactsService: self.contactsService,
                                                        callsProvider: self.callsProvider, requestsService: self.requestsService, profileService: self.profileService,
                                                        presenceService: self.presenceService)
        self.videoManager = VideoManager(with: self.callService, videoService: self.videoService)

        self.voipRegistry.delegate = self

        // Start the C++ daemon on a background thread so the main thread (and UI) stays
        // responsive during the lengthy libjami::init() + start() calls (3-8 s on device).
        // All follow-up work that needs the daemon is queued inside the completion block
        // and dispatched back to the main thread once the daemon is ready.
        // A 1-second delay lets the network stack settle (IPv4/IPv6 interface selection)
        // before libjami begins TLS handshakes, preventing a use-after-free crash in
        // ASIO's tls13_send_alert when IPv6 drops immediately after init.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.startDaemon()
            self.setUpTestDataIfNeed()
            DispatchQueue.main.async {
                // [TALK9] Prewarm guard. iOS 15+ can prewarm-launch the app:
                // didFinishLaunching runs but no scene ever becomes active. The
                // daemon still starts here and registers accounts on the DHT from
                // a background process the user never opened — consuming DHT
                // values before the NSE can decrypt them (decrypt=.unknown →
                // suppressed/empty notifications instead of real banners).
                // When launching straight into .background (prewarm or a silent
                // background relaunch), keep accounts inactive: the NSE owns
                // pushes. appMovedForeground (ConversationsManager) restores the
                // active state when the user actually opens the app.
                // A VoIP cold launch ALSO lands here with .background (answering
                // from the lock screen never foregrounds the app), and the
                // previewPendingCall activation fired before the daemon existed —
                // so never deactivate while a call is in flight, or the account
                // never registers and the 15 s unhandeled-call timeout kills the
                // call. Post-call cleanup is updateBackgroundState's job.
                if UIApplication.shared.applicationState == .background
                    && !self.presentingCallScreen
                    && !self.callsProvider.hasActiveCalls() {
                    self.log.debug("[Talk9-Diag] background launch (prewarm?) — keeping accounts inactive")
                    self.accountService.setAccountsActive(active: false)
                }
                self.prepareAccounts()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(registerNotifications),
                                               name: NSNotification.Name(rawValue: NotificationName.enablePushNotifications.rawValue),
                                               object: nil)
        // Unregister from VOIP notifications when all accounts have notifications disabled.
        NotificationCenter.default.addObserver(self, selector: #selector(unregisterNotifications),
                                               name: NSNotification.Name(rawValue: NotificationName.disablePushNotifications.rawValue),
                                               object: nil)

        // [TALK9] Badge is cleared in sceneDidBecomeActive, NOT here: iOS 15+
        // prewarming invokes didFinishLaunching with no user interaction, so
        // clearing here silently wiped the badge before the user ever saw it.
        if let path = self.certificatePath() {
            setenv("CA_ROOT_FILE", path, 1)
        }
        return true
    }

    func addListenerForNotification() {
        // notify_register_dispatch delivers straight onto our own queue —
        // unlike CFNotificationCenter's darwin observer, whose callback only
        // fires once the MAIN run loop turns.
        let status = notify_register_dispatch(Constants.notificationReceived as String,
                                              &handshakeNotifyToken,
                                              handshakeQueue) { [weak self] _ in
            self?.handlePushHandshake()
        }
        if status != 0 { // NOTIFY_STATUS_OK
            log.error("AppDelegate: notify_register_dispatch failed (\(status)) — push handshake unavailable")
        }
    }

    func certificatePath() -> String? {
        let fileName = "cacert"
        let filExtension = "pem"
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let certPath = documentsURL.appendingPathComponent(fileName).appendingPathExtension(filExtension)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: certPath.path) {
            return certPath.path
        }
        guard let certSource = Bundle.main.url(forResource: fileName, withExtension: filExtension) else {
            return nil
        }
        do {
            try fileManager.copyItem(at: certSource, to: certPath)
            return certPath.path
        } catch {
            return nil
        }
    }

    func prepareAccounts() {
        self.accountService
            .needMigrateCurrentAccount
            .subscribe(onNext: { account in
                DispatchQueue.main.async {
                    self.appCoordinator.migrateAccount(accountId: account)
                }
            })
            .disposed(by: self.disposeBag)
        self.accountService.initialAccountsLoading()
            .subscribe(onCompleted: {
                DispatchQueue.main.async {
                    // processPendingNotification must run BEFORE initialLoadingCompleted so
                    // that conversationsCoordinator does not exist yet when openConversation
                    // is called.  If the coordinator already exists, openConversation bypasses
                    // pendingNavigation and calls openConversationFromNotification immediately —
                    // before reloadDataFor has had a chance to populate the conversation list.
                    // Running it first causes openConversation to save to pendingNavigation;
                    // processPendingNavigation then fires 0.5 s after showMainInterface(), giving
                    // the DB load a head start before the retry loop begins.
                    self.processPendingNotification()
                    self.appCoordinator.initialLoadingCompleted()
                    self.recoverFromInterruptedReregister()
                }
                // set selected account if exists
                if !self.accountService.hasAccounts() {
                    // Set default download transfer limit to 20MB.
                    let userDefaults = UserDefaults.standard
                    if userDefaults.object(forKey: acceptTransferLimitKey) == nil {
                        userDefaults.set(20, forKey: acceptTransferLimitKey)
                    }
                    if userDefaults.object(forKey: hardareAccelerationKey) == nil {
                        self.videoService.setHardwareAccelerated(withState: true)
                        UserDefaults.standard.set(true, forKey: hardareAccelerationKey)
                    }
                    if userDefaults.object(forKey: limitLocationSharingDurationKey) == nil {
                        UserDefaults.standard.set(true, forKey: limitLocationSharingDurationKey)
                    }
                    if userDefaults.object(forKey: locationSharingDurationKey) == nil {
                        UserDefaults.standard.set(15, forKey: locationSharingDurationKey)
                    }
                    return
                }
                if self.accountService.hasAccountWithProxyEnabled() {
                    self.registerNotifications()
                } else {
                    self.unregisterNotifications()
                }

                let sharedDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier)
                let standardDefaults = UserDefaults.standard

                if let selectedAccountID = sharedDefaults?.string(forKey: Constants.selectedAccountID),
                   let account = self.accountService.getAccount(fromAccountId: selectedAccountID) {
                    self.accountService.currentAccount = account
                } else if let selectedAccountID = standardDefaults.string(forKey: Constants.selectedAccountID),
                          let account = self.accountService.getAccount(fromAccountId: selectedAccountID) {
                    self.accountService.currentAccount = account
                    sharedDefaults?.set(account.id, forKey: Constants.selectedAccountID)
                }

                guard let currentAccount = self.accountService.currentAccount else {
                    self.log.error("Unable to get current account!")
                    return
                }
                DispatchQueue.global(qos: .background).async {[weak self] in
                    guard let self = self else { return }
                    self.reloadDataFor(account: currentAccount)
                }
            }, onError: { _ in
                self.appCoordinator.showInitialLoading()
                let time = DispatchTime.now() + 1
                DispatchQueue.main.asyncAfter(deadline: time) {
                    self.appCoordinator.showDatabaseError()
                }
            })
            .disposed(by: self.disposeBag)

        self.accountService.currentWillChange
            .subscribe(onNext: { account in
                guard let currentAccount = account else { return }
                self.conversationsService.clearConversationsData(accountId: currentAccount.id)
                self.presenceService.subscribeBuddies(withAccount: currentAccount.id, withContacts: self.contactsService.contacts.value, subscribe: false)
            })
            .disposed(by: self.disposeBag)

        self.accountService.currentAccountChanged
            .subscribe(onNext: { account in
                guard let currentAccount = account else { return }
                self.reloadDataFor(account: currentAccount)
            })
            .disposed(by: self.disposeBag)
    }

    func updateCallScreenState(presenting: Bool) {
        self.presentingCallScreen = presenting
    }

    func reloadDataFor(account: AccountModel) {
        // prepareConversationsForAccount below rebuilds every ConversationModel
        // (ConversationsService.addSwarm constructs new instances), so the Trigger 1b
        // subscriptions made for the previous set now watch objects that are about to
        // be discarded. Drop them, and clear the watched-id set along with them:
        // leaving stale ids in place makes Trigger 1's `insert().inserted` guard skip
        // the fresh models, and a conversation stuck in `synchronizing` then never
        // gets its 30 s re-register — it just sits on "Syncing…" forever.
        // Hopping to main keeps every access to syncWatchedIds on one thread.
        // See NOTIFICATIONS.md §4 D2.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncWatchedIds.removeAll()
            self.syncWatchDisposeBag = DisposeBag()
        }

        self.requestsService.loadRequests(withAccount: account.id, accountURI: account.jamiId)
        self.conversationManager?
            .prepareConversationsForAccount(accountId: account.id, accountURI: account.jamiId)
        self.contactsService.loadContacts(withAccount: account)
        self.presenceService.subscribeBuddies(withAccount: account.id, withContacts: self.contactsService.contacts.value, subscribe: true)
        // On cold start or account switch, scan for messages that were left stuck in
        // "sending" from a previous session.  Wait 20 s so conversations have time to
        // load and the account has time to register before we make any judgements.
        let accountId = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
            self?.markStuckMessagesAsFailed(accountId: accountId)
        }
    }

    // MARK: - Scene Lifecycle Methods

    func sceneDidEnterBackground() {
        handshakeQueue.async { [weak self] in self?.appIsInBackgroundForHandshake = true }
        guard let account = self.accountService.currentAccount else { return }
        self.presenceService.subscribeBuddies(withAccount: account.id, withContacts: self.contactsService.contacts.value, subscribe: false)
    }

    func sceneWillEnterForeground() {
        handshakeQueue.async { [weak self] in self?.appIsInBackgroundForHandshake = false }
        self.updateNotificationAvailability()
        guard let account = self.accountService.currentAccount else {
            self.daemonService.connectivityChanged()
            return
        }
        // Re-apply Talk9 TURN/bootstrap settings before triggering connectivity.
        // The daemon can silently reset these to Jami defaults while the app is
        // in the background, which breaks ICE for all subsequent connection attempts.
        log.debug("[Talk9-Diag] 📲 sceneWillEnterForeground — re-applying TURN + connectivityChanged, resetting syncRetryCount")
        accountService.applyTalk9NetworkDefaults(accountId: account.id)
        self.daemonService.connectivityChanged()
        // Reset the retry counter so the watchdog can fire again after the user
        // brings the app back to the foreground.  Without this reset, after 5 failed
        // attempts in one session the watchdog is permanently silenced until the
        // app is killed and relaunched — even if connectivity later recovers.
        syncRetryCount = 0
        reRegisterBackoff = 30
        nextReRegisterAllowedAt = Date.distantPast
        self.presenceService.subscribeBuddies(withAccount: account.id, withContacts: self.contactsService.contacts.value, subscribe: true)
        // [TALK9] Also subscribe to presence for ALL conversation participants, not just contacts.
        // The daemon's rotateTrackedMembers() has a bug where it permanently untracks a peer
        // after ICE failure in a 2-person conversation. Maintaining a Swift-side presence
        // subscription (refCount ≥ 1) prevents a full untrack, keeping the DHT listener alive
        // so iOS receives the peer's next presence announcement and retries ICE.
        self.subscribeAllConversationParticipants(accountId: account.id, subscribe: true)
        // [TALK9] RC3: resume-from-suspend may not emit a fresh REGISTERED event,
        // so also sweep here. Gated on an already-registered account — during a
        // cold start this runs before the daemon is ready and the REGISTERED
        // observer performs the sweep instead (issuing fetches mid-JAMS-init is
        // the exact BoringSSL crash the old startup sync died of).
        if account.status == .registered {
            self.performThrottledActiveSync(accountId: account.id)
        }
    }

    func sceneDidBecomeActive() {
        self.clearBadgeNumber()
        self.removePendingNotifications()
        guard let account = self.accountService.currentAccount else { return }
        self.presenceService.subscribeBuddies(withAccount: account.id, withContacts: self.contactsService.contacts.value, subscribe: true)
        self.startConnectionTimers()
        // [TALK9] Drain pushes that arrived while the app was backgrounded.
        // The NSE saves every push payload to notificationData, but the only
        // drains were (a) handlePushHandshake — requires the app to be foreground
        // at the moment the push arrives — and (b) the banner-tap path. Opening
        // the app from the ICON left the entries stranded: the daemon never got
        // the DHT-fetch nudge, so the message behind the banner didn't arrive
        // until a retry trigger or a relogin. processPendingPushDataWhenReady
        // handles the cold-start case (defers feeding the daemon until this
        // account's conversations are loaded) and is a no-op when nothing is
        // pending.
        self.processPendingPushDataWhenReady(conversationId: "", accountId: account.id)
        // [TALK9] Refresh the NSE suppression set from daemon's view of removed
        // conversations. Catches convs the user left before this fix was added.
        self.conversationsService.seedLeftConversationsSuppressionSet(accountId: account.id)
        // [TALK9] Snapshot active convs into shared UserDefaults so the NSE
        // whitelist check can drop phantom pushes for convs the daemon has
        // already purged after a sync (where the left set no longer has them).
        self.conversationsService.refreshActiveConversationsSet(accountId: account.id)
        // [TALK9] Startup-time syncConversation(accountId, "") used to live here
        // but crashed the daemon on cold start (concurrent fetchNewCommits SSL
        // handshakes during JAMS init corrupted BoringSSL). Its replacement is
        // performThrottledActiveSync(): gated on REGISTERED, staggered per
        // conversation, triggered from the registrationStateChanged observer
        // and sceneWillEnterForeground.
    }

    func sceneWillResignActive() {
        guard let account = self.accountService.currentAccount else { return }
        self.presenceService.subscribeBuddies(withAccount: account.id, withContacts: self.contactsService.contacts.value, subscribe: false)
        self.subscribeAllConversationParticipants(accountId: account.id, subscribe: false)
        self.stopConnectionTimers()
    }

    // MARK: - Connection Retry Helpers

    // UserDefaults key that marks an in-progress re-register cycle.
    // Written before enableAccount(false), cleared after enableAccount(true).
    // If the app is killed in the 1.5 s gap, this key survives and lets us
    // re-enable the account on next startup instead of showing Offline.
    private let talk9ReenablePendingKey = "talk9_reenable_pending"

    // Notification tap that arrived before accounts were loaded (cold-start deep link).
    // Replayed in processPendingNotification() once initialAccountsLoading completes.
    private var pendingNotificationData: [AnyHashable: Any]?
    private var pendingNotificationActionId: String = UNNotificationDefaultActionIdentifier

    // Tracks how many times we have re-registered due to stuck sync per session, to avoid infinite loop.
    // Reset to 0 when a conversation successfully syncs (conversationReady fires).
    private var syncRetryCount = 0
    private let maxSyncRetries = 5
    // [TALK9] R8: central backoff gate. Every trigger funnels through
    // reRegisterAccountForSyncRetry, but several of them reset syncRetryCount
    // (Trigger5/6, foreground return), which made the retry cap toothless: an
    // unstable network could disable/enable the account every few seconds, and
    // each cycle is a ~1.5 s + registration-time blind window during which
    // pushes fed to the disabled account are dropped. The time gate is
    // independent of the counter: consecutive re-registers spread
    // 30s→60s→120s→240s→300s, and the ladder only resets on real success
    // (conversationReady) or a fresh foreground session.
    private var nextReRegisterAllowedAt = Date.distantPast
    private var reRegisterBackoff: TimeInterval = 30
    // Conversation IDs already being watched for stuck sync (avoids duplicate subscriptions).
    private var syncWatchedIds: Set<String> = []
    /// Holds the per-conversation `synchronizing` subscriptions from Trigger 1b.
    /// Replaced whenever the conversation models are rebuilt, because those
    /// subscriptions then point at discarded instances. Kept apart from the app-level
    /// `disposeBag`, which never releases. See NOTIFICATIONS.md §4 D2.
    private var syncWatchDisposeBag = DisposeBag()
    // When true, the next REGISTERED event triggers swarm re-bootstrap.
    // Set to true after enableAccount(true) in reRegisterAccountForSyncRetry.
    private var pendingSwarmBootstrapOnRegistered = false
    // Prevents Trigger6 (SwarmBootstrapFailed) from firing more than once per 60s.
    private var lastSwarmBootstrapRetry: Date = .distantPast

    /// Subscribe to per-conversation synchronizing state AND to member-join events.
    ///
    /// Two triggers for account re-registration:
    ///
    /// 1. INVITEE path — conversation enters `synchronizing=true`:
    ///    After 30 s still stuck → re-register.  The daemon's 40-second retry timer then
    ///    sees a fresh account online and retries ICE, completing the git-clone.
    ///
    /// 2. INVITER path — peer accepts (conversationMemberEvent fires):
    ///    Inviter already has the conversation (`synchronizing` stays false), but the
    ///    new peer needs to clone it over ICE.  After 30 s → re-register so JAMS
    ///    announces iOS is online, causing the peer to retry ICE from their side.
    ///
    /// `maxSyncRetries` caps total re-registrations per session to avoid loops.
    private func subscribeConversationSyncRetry() {
        // Reset retry counter when any conversation successfully syncs.
        self.conversationsService.conversationReady
            .filter { !$0.isEmpty }
            .subscribe(onNext: { [weak self] _ in
                self?.syncRetryCount = 0
                // Success also clears the backoff ladder: the next incident
                // starts again at 30 s.
                self?.reRegisterBackoff = 30
                self?.nextReRegisterAllowedAt = Date.distantPast
            })
            .disposed(by: self.disposeBag)

        // Trigger 1: watch every conversation exactly once per model generation.
        // Observed on main so syncWatchedIds is only ever touched from one thread —
        // `conversations.accept` fires on whichever queue the reload ran on.
        self.conversationsService.conversations
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] conversations in
                guard let self = self else { return }
                for conv in conversations {
                    guard self.syncWatchedIds.insert(conv.id).inserted else { continue }

                    // 1a. INVITER path (startup/foreground): conversation already has
                    //     non-local participants whose role is still .invited — they
                    //     haven't cloned the conversation yet. Re-register after 10 s to
                    //     give JAMS a chance to push "iOS is online" to the other side.
                    let hasInvited = conv.getAllParticipants()
                        .filter { !$0.isLocal }
                        .contains { $0.role == .invited }
                    if hasInvited {
                        let convId = String(conv.id.prefix(8))
                        log.debug("[Talk9-ICE][Retry] Trigger1a — invited peer detected for conv=\(convId), will re-register in 10s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            self?.log.debug("[Talk9-ICE][Retry] Trigger1a firing reRegister for conv=\(convId)")
                            self?.reRegisterAccountForSyncRetry()
                        }
                    }

                    // 1b. INVITEE path: re-register if synchronizing stays true for 30 s.
                    conv.synchronizing
                        .asObservable()
                        .filter { $0 }   // fires each time synchronizing becomes true
                        .subscribe(onNext: { [weak self, weak conv] _ in
                            let convId = String(conv?.id.prefix(8) ?? "?")
                            self?.log.debug("[Talk9-ICE][Retry] Trigger1b — conv=\(convId) synchronizing=true, will re-register in 30s if still stuck")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak conv] in
                                guard conv?.synchronizing.value == true else { return }
                                self?.log.debug("[Talk9-ICE][Retry] Trigger1b firing reRegister — conv=\(convId) still synchronizing after 30s")
                                self?.reRegisterAccountForSyncRetry()
                            }
                        })
                        .disposed(by: self.syncWatchDisposeBag)
                }
            })
            .disposed(by: self.disposeBag)

        // Trigger 2: when a peer joins a conversation (INVITER path).
        // Re-register 30 s after any member event so the peer (who just accepted)
        // gets a JAMS nudge to retry ICE against iOS.
        self.conversationsService.sharedResponseStream
            .filter { $0.eventType == .conversationMemberEvent }
            .subscribe(onNext: { [weak self] _ in
                self?.log.debug("[Talk9-ICE][Retry] Trigger2 — memberEvent received, will re-register in 30s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.log.debug("[Talk9-ICE][Retry] Trigger2 firing reRegister after memberEvent")
                    self?.reRegisterAccountForSyncRetry()
                }
            })
            .disposed(by: self.disposeBag)

        #if DEBUG
        // Trigger 3 (DEBUG only): manual force button in the debug overlay.
        NotificationCenter.default.addObserver(forName: .debugForceReRegister, object: nil, queue: .main) { [weak self] _ in
            self?.syncRetryCount = 0      // reset limit so manual force always works
            self?.nextReRegisterAllowedAt = Date.distantPast
            self?.reRegisterAccountForSyncRetry()
        }
        #endif

        // Trigger: after re-register (enableAccount true), wait for REGISTERED state,
        // then re-bootstrap swarm. Using REGISTERED event ensures TURN cache has been
        // refreshed (turnCache_->refresh() is called in the daemon when REGISTERED fires)
        // before we call loadConversations() → bootstrap() → maintainBuckets() → ICE.
        self.accountService.sharedResponseStream
            .filter { $0.eventType == .registrationStateChanged }
            .compactMap { event -> String? in
                guard let stateStr: String = event.getEventInput(.registrationState),
                      let accountId: String = event.getEventInput(.accountId) else { return nil }
                return stateStr == AccountState.registered.rawValue ? accountId : nil
            }
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] accountId in
                guard let self = self else { return }
                // [TALK9] RC3: every REGISTERED (cold start included) gets one
                // throttled active sync — the safe replacement for the disabled
                // startup-time sync. See performThrottledActiveSync().
                self.performThrottledActiveSync(accountId: accountId)
                guard self.pendingSwarmBootstrapOnRegistered else { return }
                self.pendingSwarmBootstrapOnRegistered = false
                self.log.debug("[Talk9-ICE][Retry] ✅ REGISTERED — re-bootstrap starting  retries=\(self.syncRetryCount)/\(self.maxSyncRetries)  account=\(accountId)")
                // 0. Re-apply Talk9 TURN/bootstrap one final time now that the daemon is
                //    REGISTERED.  The daemon refreshes its TURN cache at this exact moment
                //    (turnCache_->refresh()), so settings applied here take effect immediately
                //    for all subsequent ICE negotiations.
                self.accountService.applyTalk9NetworkDefaults(accountId: accountId)
                // 1. Force loadConversations() → bootstrap() → swarmManager.restart() + maintainBuckets()
                self.conversationsService.reloadConversationsAndRequests(accountId: accountId)
                // 2. Also trigger ICE candidate re-discovery and DHT re-bootstrap
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.daemonService.connectivityChanged()
                }
                // 3. After giving the reconnected channel time to drain naturally,
                //    mark any messages that are still stuck as failed so the user
                //    can see and manually retry them instead of waiting forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    self?.markStuckMessagesAsFailed(accountId: accountId)
                }
            })
            .disposed(by: self.disposeBag)

        // Trigger 4: stuck-sending watchdog.
        // When a message enters "sending" status, start a 90-second timer.
        // If it is still "sending" after 90 s (peer never acknowledged), re-register
        // to unblock the swarm connection (same mechanism as Triggers 1–2).
        NotificationCenter.default.addObserver(forName: .messageStatusSending, object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let messageId = notification.userInfo?["messageId"] as? String else { return }
            // Cancel any prior watchdog for this message
            self.sendingWatchdogTimers[messageId]?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.sendingWatchdogTimers.removeValue(forKey: messageId)
                // Confirm the message is genuinely still in "sending"
                let isStillSending = self.conversationsService.conversations.value.contains { conv in
                    conv.messages.contains { msg in
                        msg.id == messageId && msg.status == .sending
                    }
                }
                guard isStillSending else { return }
                self.log.debug("[Talk9-ICE][Retry] Trigger4 — message \(messageId) stuck 90s sending, firing reRegister")
                self.reRegisterAccountForSyncRetry()
            }
            self.sendingWatchdogTimers[messageId] = timer
        }

        // Cancel watchdog when message is delivered or fails.
        NotificationCenter.default.addObserver(forName: .messageStatusFinalized, object: nil, queue: .main) { [weak self] notification in
            guard let messageId = notification.userInfo?["messageId"] as? String else { return }
            self?.sendingWatchdogTimers[messageId]?.invalidate()
            self?.sendingWatchdogTimers.removeValue(forKey: messageId)
        }

        // Trigger 6: daemon reported SwarmBootstrapFailed (all ICE/TURN candidates exhausted).
        // Without this, after a failure there is no retry unless a message gets stuck 90s (Trigger4)
        // or a member event fires (Trigger2) — both of which may never happen for new contacts.
        NotificationCenter.default.addObserver(forName: .swarmBootstrapFailed, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let convId = (notification.userInfo?["conversationId"] as? String).map { String($0.prefix(8)) } ?? "?"
            // Debounce: don't retry more than once per 60s to avoid hammering the server.
            let now = Date()
            guard now.timeIntervalSince(self.lastSwarmBootstrapRetry) > 60 else {
                self.log.debug("[Talk9-ICE][Retry] Trigger6 debounced for conv=\(convId) (last retry < 60s ago)")
                return
            }
            self.lastSwarmBootstrapRetry = now
            self.log.debug("[Talk9-ICE][Retry] Trigger6 — SwarmBootstrapFailed conv=\(convId), scheduling reRegister in 15s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.log.debug("[Talk9-ICE][Retry] Trigger6 firing reRegister for conv=\(convId)")
                self?.syncRetryCount = 0
                self?.reRegisterAccountForSyncRetry()
            }
        }

        // Trigger 5: call ended with ICE failure (pjsipCode 480/503/404).
        // The peer's device was untracked by the daemon after ICE failed, so the next
        // call attempt will also fail unless we re-register to restart the swarm tracking.
        NotificationCenter.default.addObserver(forName: .callFailedWithICEError, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let code = notification.userInfo?["stateCode"] as? Int ?? 0
            let callId = notification.userInfo?["callId"] as? String ?? "?"
            self.log.debug("[Talk9-ICE][Retry] Trigger5 — call \(callId) failed pjsipCode=\(code), resetting retry counter + re-registering")
            self.syncRetryCount = 0
            self.reRegisterAccountForSyncRetry()
        }
    }

    // [TALK9] RC3 — timestamp of the last active-sync sweep (main thread only).
    private var lastActiveSyncAt = Date.distantPast

    /// [TALK9] RC3 — throttled ACTIVE conversation sync (passive-receive gap fix).
    /// An already-synced conversation has no proactive pull anywhere: incoming
    /// messages rely on the live swarm connection or a push reaching a running
    /// daemon. If the peer was offline while we were, nothing self-heals until
    /// relogin. The original startup-time `syncConversation(accountId, "")` was
    /// disabled because issuing many concurrent fetchNewCommits SSL handshakes
    /// while the daemon was still initializing JAMS auth corrupted BoringSSL
    /// (cold-start crash). This is the fix prescribed by that comment: gate on
    /// REGISTERED (JAMS auth complete, TURN cache refreshed) and stagger the
    /// fetches per conversation instead of one fan-out-everything call.
    /// The daemon dedups overlapping fetches per conversation (conv->pending),
    /// so a sweep racing the reactive paths is safe.
    private func performThrottledActiveSync(accountId: String, allowRetry: Bool = true) {
        // Registration can flap (network changes, re-register cycles) — don't
        // restart the sweep more than once a minute.
        guard Date().timeIntervalSince(lastActiveSyncAt) > 60 else { return }
        let conversationIds = conversationsService.conversations.value
            .filter { $0.accountId == accountId && !$0.id.isEmpty }
            .map { $0.id }
        guard !conversationIds.isEmpty else {
            // On a cold start REGISTERED can beat the async DB load, leaving the
            // list empty. One deferred retry is enough — if it is still empty
            // then, there is genuinely nothing to sync. The throttle timestamp
            // is deliberately NOT set here so the retry passes it.
            if allowRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    self?.performThrottledActiveSync(accountId: accountId, allowRetry: false)
                }
            }
            return
        }
        lastActiveSyncAt = Date()
        log.debug("[Talk9-Diag] active sync sweep: \(conversationIds.count) conversations for account \(accountId)")
        // 3 s head start lets the post-REGISTERED bootstrap settle; 0.4 s stagger
        // keeps the number of simultaneous SSL handshakes bounded.
        for (index, convId) in conversationIds.enumerated() {
            let delay = 3.0 + 0.4 * Double(index)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.conversationsService.syncConversation(accountId: accountId,
                                                            conversationId: convId)
            }
        }
    }

    /// Re-registers the current account by toggling enable state.
    /// This triggers JAMS re-authentication and announces iOS as "newly online",
    /// causing Android to initiate a fresh connection (same effect as app restart).
    private func reRegisterAccountForSyncRetry() {
        let now = Date()
        guard now >= nextReRegisterAllowedAt else {
            log.debug("[Talk9-ICE][Retry] backoff gate — next re-register allowed in \(Int(nextReRegisterAllowedAt.timeIntervalSince(now)))s")
            return
        }
        guard syncRetryCount < maxSyncRetries else {
            log.warning("[Talk9-ICE][Retry] ❌ retry limit reached (\(maxSyncRetries)) — no more reconnect attempts this session")
            return
        }
        guard let account = accountService.currentAccount else { return }
        // Don't re-register if there is an active call — it would drop it
        if callService.calls.get().values.contains(where: { $0.state == .current }) {
            log.debug("[Talk9-ICE][Retry] skipping — active call in progress")
            return
        }

        nextReRegisterAllowedAt = now.addingTimeInterval(reRegisterBackoff)
        reRegisterBackoff = min(reRegisterBackoff * 2, 300)
        syncRetryCount += 1
        log.debug("[Talk9-ICE][Retry] 🔄 attempt \(syncRetryCount)/\(maxSyncRetries)  account=\(account.id)")
        // Force-restore Talk9 TURN/bootstrap before disable — daemon can silently reset
        // these to Jami defaults on account re-enable, which breaks ICE for all peers.
        accountService.applyTalk9NetworkDefaults(accountId: account.id)
        #if DEBUG
        NotificationCenter.default.post(name: .debugReRegisterFired, object: nil)
        #endif
        // Mark that we are mid-cycle BEFORE disabling. If the app is killed during the
        // 1.5 s gap, this key survives to disk and lets startup re-enable the account.
        UserDefaults.standard.set(account.id, forKey: talk9ReenablePendingKey)
        accountService.enableAccount(accountId: account.id, enable: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            // Clear the flag first — re-enable is about to happen normally.
            UserDefaults.standard.removeObject(forKey: self.talk9ReenablePendingKey)
            // Re-apply Talk9 TURN/bootstrap AGAIN just before re-enabling the account.
            // The daemon resets these settings to Jami defaults when an account is
            // re-enabled, so applying them only before disable (above) is not enough —
            // they must be set here, immediately before enableAccount(true), so the
            // daemon picks up the correct Talk9 servers on its next registration attempt.
            self.accountService.applyTalk9NetworkDefaults(accountId: account.id)
            // Signal that we want a swarm re-bootstrap once REGISTERED is confirmed.
            // `registrationStateChanged` observer in subscribeConversationSyncRetry()
            // will call reloadConversationsAndRequests + connectivityChanged at that point,
            // ensuring the swarm managers are restarted AFTER the TURN cache is refreshed.
            self.pendingSwarmBootstrapOnRegistered = true
            self.accountService.enableAccount(accountId: account.id, enable: true)
        }
    }

    /// Called once on startup. If the app was killed during the 1.5 s disable→enable
    /// window of a re-register cycle, the account is still disabled on disk. This method
    /// detects that situation via the UserDefaults flag and re-enables the account.
    private func recoverFromInterruptedReregister() {
        guard let accountId = UserDefaults.standard.string(forKey: talk9ReenablePendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: talk9ReenablePendingKey)
        guard accountService.getAccount(fromAccountId: accountId) != nil else { return }
        log.debug("[Talk9-ICE] Recovering interrupted re-register — re-enabling account \(accountId)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.accountService.applyTalk9NetworkDefaults(accountId: accountId)
            self.accountService.enableAccount(accountId: accountId, enable: true)
        }
    }

    /// Scans all conversations for outgoing messages that have been stuck in "sending"
    /// for longer than `stuckThreshold` seconds and marks them as failed.
    ///
    /// This is called in two situations:
    ///   1. After a reconnect (REGISTERED fires) — gives the newly restored connection
    ///      10 s to drain any legitimately queued messages before declaring them dead.
    ///   2. On cold start / account load — gives 20 s for conversations to load and
    ///      the account to register before checking for leftover stuck messages from
    ///      a previous session.
    ///
    /// Marking stuck messages as `.failure` lets the user see the real state and
    /// manually retry, rather than watching a spinner forever.
    private func markStuckMessagesAsFailed(accountId: String) {
        // A message is "stuck" if it has been in sending state for more than this
        // many seconds.  We use 90 s to match the existing Trigger 4 watchdog window,
        // so we only act on messages that the watchdog already had a chance to retry.
        let stuckThreshold: TimeInterval = 90
        let now = Date()
        let localJamiId = accountService.currentAccount?.jamiId ?? ""

        for conversation in conversationsService.conversations.value
                where conversation.accountId == accountId {

            // Outgoing messages have an empty authorId (the local user is the author).
            let stuckMessages = conversation.messages.filter { msg in
                msg.status == .sending &&
                msg.authorId.isEmpty &&
                now.timeIntervalSince(msg.receivedDate) > stuckThreshold
            }

            guard !stuckMessages.isEmpty else { continue }

            // For the status-change callback we need the remote peer's jamiId.
            // In a 1-to-1 conversation this is the only non-local participant;
            // for group conversations an empty string is acceptable.
            let peerJamiId = conversation.getParticipants()
                .first(where: { $0.jamiId != localJamiId })?.jamiId ?? ""

            for msg in stuckMessages {
                log.debug("AppDelegate: message \(msg.id) stuck in sending for >\(Int(stuckThreshold))s — marking as failed")
                conversationsService.messageStatusChanged(
                    .failure,
                    for: msg.id,
                    from: accountId,
                    to: peerJamiId,
                    in: conversation.id
                )
            }
        }
    }

    /// Subscribe (or unsubscribe) presence for every non-local participant across all
    /// conversations. This keeps a Swift-side DHT presence reference alive for peers that
    /// are not yet in the contacts list (e.g. a newly invited user), preventing the
    /// daemon's rotateTrackedMembers bug from fully untracking them after ICE failure.
    private func subscribeAllConversationParticipants(accountId: String, subscribe: Bool) {
        let localJamiId = accountService.currentAccount?.jamiId ?? ""
        for conversation in conversationsService.conversations.value {
            for participant in conversation.getAllParticipants() where !participant.isLocal {
                let jamiId = participant.jamiId
                guard !jamiId.isEmpty, jamiId != localJamiId else { continue }
                presenceService.subscribeBuddy(withAccountId: accountId,
                                               withJamiId: jamiId,
                                               withFlag: subscribe)
            }
        }
    }

    private func startConnectionTimers() {
        stopConnectionTimers()
        connectivityTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.log.debug("AppDelegate: periodic connectivityChanged (TURN keepalive + bootstrap)")
            self?.daemonService.connectivityChanged()
        }
    }

    private func stopConnectionTimers() {
        connectivityTimer?.invalidate()
        connectivityTimer = nil
    }

    func applicationWillTerminate(_ application: UIApplication) {
        self.callsProvider.stopAllUnhandeledCalls()
        self.cleanTestDataIfNeed()
        self.stopDaemon()
    }

    // MARK: - Ring Daemon
    private func startDaemon() {
        do {
            try self.daemonService.startDaemon()
        } catch StartDaemonError.initializationFailure {
            log.error("Daemon failed to initialize.")
        } catch StartDaemonError.startFailure {
            log.error("Daemon failed to start.")
        } catch StartDaemonError.daemonAlreadyRunning {
            log.error("Daemon already running.")
        } catch {
            log.error("Unknown error in Daemon start.")
        }
    }

    private func stopDaemon() {
        do {
            try self.daemonService.stopDaemon()
        } catch StopDaemonError.daemonNotRunning {
            log.error("Daemon failed to stop because it was not already running.")
        } catch {
            log.error("Unknown error in Daemon stop.")
        }
    }

    func updateNotificationAvailability() {
        let enabled = LocalNotificationsHelper.isEnabled()
        let currentSettings = UNUserNotificationCenter.current()
        currentSettings.getNotificationSettings(completionHandler: { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                break
            case .denied:
                if enabled { LocalNotificationsHelper.setNotification(enable: false) }
            case .authorized:
                if !enabled { LocalNotificationsHelper.setNotification(enable: true) }
            case .provisional:
                if !enabled { LocalNotificationsHelper.setNotification(enable: true) }
            case .ephemeral:
                if enabled { LocalNotificationsHelper.setNotification(enable: false) }
            @unknown default:
                break
            }
        })
    }

    /// Runs on handshakeQueue. Same policy as before: backgrounded with no
    /// call in flight → stay silent, the NSE owns the push.
    private func handlePushHandshake() {
        // presentingCallScreen / CXCallObserver are written on other threads,
        // but a stale read here only shifts WHO handles the push (app vs NSE),
        // and both paths are correct — no synchronization needed.
        if appIsInBackgroundForHandshake && !presentingCallScreen && !callsProvider.hasActiveCalls() {
            return
        }
        // Reply first — this races the NSE's 0.3 s window; the drain below is
        // not latency-critical.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Constants.notificationAppIsActive),
                                             nil, nil, true)
        for data in Talk9PushQueue.drain() {
            self.accountService.pushNotificationReceived(data: data)
        }
    }

    @objc
    private func registerNotifications() {
        self.requestNotificationAuthorization()
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
        self.voipRegistry.desiredPushTypes = Set([PKPushType.voIP])
    }

    @objc
    private func unregisterNotifications() {
        DispatchQueue.main.async {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
        self.voipRegistry.desiredPushTypes = nil
        self.accountService.setPushNotificationToken(token: "")
    }

    private func requestNotificationAuthorization() {
        let application = UIApplication.shared
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = application.delegate as? UNUserNotificationCenterDelegate
            let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
            UNUserNotificationCenter.current().requestAuthorization(options: authOptions, completionHandler: { (enable, _) in
                if enable {
                    LocalNotificationsHelper.setNotification(enable: true)
                } else {
                    LocalNotificationsHelper.setNotification(enable: false)
                }
            })
        }
    }

    private func removePendingNotifications() {
        guard let defaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else { return }
        let pending = defaults.stringArray(forKey: Constants.pendingNotificationRemovalKey) ?? []
        if !pending.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: pending)
            defaults.removeObject(forKey: Constants.pendingNotificationRemovalKey)
        }
        // Full sweep: also remove any orphaned "talk9.suppressed" notifications.
        // NSE's per-push cleanup is best-effort (scheduleAutoRemove dies with the
        // extension process; removeDeliveredNotifications is async). When neither
        // fires, empty cards accumulate on the lock screen. Catch them all here.
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let orphans = notifications
                .filter { $0.request.content.threadIdentifier == "talk9.suppressed" }
                .map { $0.request.identifier }
            if !orphans.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: orphans)
            }
        }
    }

    private func clearBadgeNumber() {
        if let userDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier) {
            userDefaults.set(0, forKey: Constants.notificationsCount)
        }

        UIApplication.shared.applicationIconBadgeNumber = 0
        // [TALK9] DO NOT call removeAllDeliveredNotifications() / removeAllPendingNotificationRequests()
        // here. iOS 15+ prewarming silently invokes application(_:didFinishLaunching:) without
        // any user interaction; the old aggressive clear would then wipe every real notification
        // off the lock screen, making users believe their notifications "disappeared on their own".
        // Per-suppressed-card cleanup is handled by removePendingNotifications() in
        // sceneDidBecomeActive (which only fires on actual scene activation).
    }

}

// MARK: notification actions
extension AppDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let data = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        self.handleNotificationActions(data: data, actionIdentifier: actionIdentifier)
        completionHandler()
    }

    func handleNotificationActions(data: [AnyHashable: Any], actionIdentifier: String) {
        guard let accountId = data[Constants.NotificationUserInfoKeys.accountID.rawValue] as? String else { return }

        guard let account = self.accountService.getAccount(fromAccountId: accountId) else {
            // Accounts not loaded yet (cold start). Save and replay after startup.
            pendingNotificationData = data
            pendingNotificationActionId = actionIdentifier
            return
        }

        self.accountService.updateCurrentAccount(account: account)

        if isCallNotification(data: data) {
            handleCallNotification(data: data, account: account, actionIdentifier: actionIdentifier)
        } else {
            handleConversationNotification(data: data, accountId: accountId)
        }
    }

    private func processPendingNotification() {
        guard let data = pendingNotificationData else { return }
        let action = pendingNotificationActionId
        pendingNotificationData = nil
        pendingNotificationActionId = UNNotificationDefaultActionIdentifier
        handleNotificationActions(data: data, actionIdentifier: action)
    }

    private func isCallNotification(data: [AnyHashable: Any]) -> Bool {
        return data[Constants.NotificationUserInfoKeys.callURI.rawValue] != nil
    }

    private func isCallAction(_ actionIdentifier: String) -> Bool {
        return actionIdentifier == Constants.NotificationAction.acceptVideo.rawValue ||
            actionIdentifier == Constants.NotificationAction.acceptAudio.rawValue
    }

    private func handleCallNotification(data: [AnyHashable: Any], account: AccountModel, actionIdentifier: String) {
        guard let conversationId = data[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }

            self.callService.updateActiveCalls(conversationId: conversationId, account: account)

            if self.isCallAction(actionIdentifier) {
                self.handleCallAction(actionIdentifier: actionIdentifier, data: data)
            } else {
                self.handleConversationNotification(data: data, accountId: account.id)
            }
        }
    }

    private func handleCallAction(actionIdentifier: String, data: [AnyHashable: Any]) {
        guard let callURI = data[Constants.NotificationUserInfoKeys.callURI.rawValue] as? String else { return }

        let isAudioOnly = actionIdentifier == Constants.NotificationAction.acceptAudio.rawValue
        self.appCoordinator.joinCall(callURI: callURI, isAudioOnly: isAudioOnly)
    }

    private func handleConversationNotification(data: [AnyHashable: Any], accountId: String) {
        let conversationId = data[Constants.NotificationUserInfoKeys.conversationID.rawValue] as? String ?? ""
        let participantID  = data[Constants.NotificationUserInfoKeys.participantID.rawValue]  as? String ?? ""

        // Process pending push data ONLY AFTER the target conversation is present in
        // conversationsService.conversations.  On a cold start (app was killed), the
        // conversation list is cleared and reloaded asynchronously by reloadDataFor().
        // Calling pushNotificationReceived() before the conversation exists causes
        // SwarmMessageReceived → newInteraction → insertMessages() to silently drop the
        // message because it can't find the conversation model.
        processPendingPushDataWhenReady(conversationId: conversationId, accountId: accountId)

        // [TALK9] Force an active pull for the targeted conversation. Reactive
        // fetchNewCommits only fires when the DHT push reaches a running daemon —
        // if A was killed when B sent, the push lands in NSE cache but no fetch
        // is triggered on app open. This proactive call closes that gap.
        if !conversationId.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.conversationsService.syncConversation(accountId: accountId, conversationId: conversationId)
            }
        }

        if !conversationId.isEmpty {
            self.appCoordinator.openConversation(conversationId: conversationId, accountId: accountId)
        } else if !participantID.isEmpty {
            self.appCoordinator.openConversation(participantID: participantID, accountId: accountId)
        }
    }

    private func processPendingPushDataWhenReady(conversationId: String, accountId: String) {
        // Check if the conversation is already available (warm start).
        let alreadyLoaded: Bool
        if conversationId.isEmpty {
            alreadyLoaded = !conversationsService.conversations.value.filter { $0.accountId == accountId }.isEmpty
        } else {
            alreadyLoaded = conversationsService.conversations.value.contains { $0.id == conversationId && $0.accountId == accountId }
        }

        if alreadyLoaded {
            processPendingPushData()
            return
        }

        // Cold start: wait for the conversation to appear in the conversations list
        // before calling pushNotificationReceived, then give it a moment to process.
        let filterBlock: ([ConversationModel]) -> Bool = { conversations in
            if conversationId.isEmpty {
                return !conversations.filter { $0.accountId == accountId }.isEmpty
            }
            return conversations.contains { $0.id == conversationId && $0.accountId == accountId }
        }

        conversationsService.conversations
            .filter(filterBlock)
            .take(1)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.processPendingPushData()
            }, onError: { [weak self] _ in
                self?.processPendingPushData()
            })
            .disposed(by: disposeBag)
    }

    private func processPendingPushData() {
        let notificationData = Talk9PushQueue.drain()
        guard !notificationData.isEmpty else { return }

        var accountIds = Set<String>()
        for data in notificationData {
            self.accountService.pushNotificationReceived(data: data)
            if let accountId = data["to"], !accountId.isEmpty {
                accountIds.insert(accountId)
            }
        }

        // Safety-net: reload conversations so any message already in local git
        // (from prior peer syncs) is surfaced immediately via conversationLoaded.
        // 1 s is enough — messages in local git arrive almost instantly; messages
        // that still need a DHT proxy fetch will arrive via newInteraction on their
        // own, independently of this timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            for accountId in accountIds {
                self.conversationsService.reloadConversationsAndRequests(accountId: accountId)
            }
        }
    }

    /// Entry point for `talk9://` links, from both a cold start and a warm resume.
    func handle(deepLink: DeepLink) {
        switch deepLink {
        case .user(let jamiId):
            self.appCoordinator.openNewConversation(jamiId: jamiId)
        case .conversation(let conversationId):
            guard let accountId = self.accountService.currentAccount?.id else { return }
            self.appCoordinator.openConversation(conversationId: conversationId, accountId: accountId)
        }
    }

    func findContactAndStartCall(hash: String, isVideo: Bool) {
        if callsProvider.hasActiveCalls() {
            return
        }
        // if saved Jami hash
        if hash.isSHA1() {
            let contactUri = JamiURI(schema: URIType.ring, infoHash: hash)
            self.findAccountAndStartCall(uri: contactUri, isVideo: isVideo, type: AccountType.ring)
            return
        }
        // if saved Jami registered name
        self.nameService.usernameLookupStatus
            .observe(on: MainScheduler.instance)
            .filter({ usernameLookupStatus in
                usernameLookupStatus.name == hash
            })
            .take(1)
            .subscribe(onNext: { usernameLookupStatus in
                if usernameLookupStatus.state == .found {
                    guard let address = usernameLookupStatus.address else { return }
                    let contactUri = JamiURI(schema: URIType.ring, infoHash: address)
                    self.findAccountAndStartCall(uri: contactUri, isVideo: isVideo, type: AccountType.ring)
                } else {
                    // if saved SIP contact
                    let contactUri = JamiURI(schema: URIType.sip, infoHash: hash)
                    self.findAccountAndStartCall(uri: contactUri, isVideo: isVideo, type: AccountType.sip)
                }
            })
            .disposed(by: self.disposeBag)
        self.nameService.lookupName(withAccount: "", nameserver: "", name: hash)
    }

    func findAccountAndStartCall(uri: JamiURI, isVideo: Bool, type: AccountType) {
        guard let currentAccount = self.accountService
                .currentAccount else { return }
        var hash = uri.hash ?? ""
        var uriString = uri.uriString ?? ""
        for account in self.accountService.accounts where account.type == type {
            if type == AccountType.sip {
                let conatactUri = JamiURI(schema: URIType.sip,
                                          infoHash: hash,
                                          account: account)
                hash = conatactUri.hash ?? ""
                uriString = conatactUri.uriString ?? ""
            }
            if hash.isEmpty || uriString.isEmpty { return }
            self.contactsService
                .getProfileForUri(uri: uriString,
                                  accountId: account.id)
                .subscribe(onNext: { (profile) in
                    if currentAccount != account {
                        self.accountService.currentAccount = account
                    }
                    self.appCoordinator
                        .startCall(participant: hash,
                                   name: profile.alias ?? "",
                                   isVideo: isVideo)
                })
                .disposed(by: self.disposeBag)
        }
    }
}

// MARK: user notifications
extension AppDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken
                        deviceToken: Data) {
        let deviceTokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print(deviceTokenString)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            self.accountService.setPushNotificationTopic(topic: bundleIdentifier)
        }
        self.accountService.setPushNotificationToken(token: deviceTokenString)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        var dictionary = [String: String]()
        for key in userInfo.keys {
            if let value = userInfo[key] {
                let keyString = String(describing: key)
                let valueString = String(describing: value)
                dictionary[keyString] = valueString
            }
        }
        self.accountService.pushNotificationReceived(data: dictionary)
        completionHandler(.newData)
    }
}

// MARK: PKPushRegistryDelegate
extension AppDelegate: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        self.updateCallScreenState(presenting: true)
        let peerId: String = payload.dictionaryPayload["peerId"] as? String ?? ""
        let hasVideo = payload.dictionaryPayload["hasVideo"] as? String ?? "true"
        let displayName = payload.dictionaryPayload["displayName"] as? String ?? ""
        let accountId = payload.dictionaryPayload["accountId"] as? String ?? ""

        var dictionary = [String: String]()
        for key in payload.dictionaryPayload.keys {
            if let value = payload.dictionaryPayload[key] {
                let keyString = String(describing: key)
                let valueString = String(describing: value)
                dictionary[keyString] = valueString
            }
        }

        callsProvider.previewPendingCall(peerId: peerId,
                                         withVideo: hasVideo.boolValue,
                                         displayName: displayName,
                                         accountId: accountId,
                                         pushNotificationPayload: dictionary) { error in
            if error != nil {
                self.updateCallScreenState(presenting: false)
            }
            completion()
        }
    }
}

// Notification names for the stuck-sending watchdog (Trigger 4).
// Posted by ConversationsService.messageStatusChanged(); consumed by AppDelegate.
extension Notification.Name {
    static let messageStatusSending   = Notification.Name("talk9.message.statusSending")
    static let messageStatusFinalized = Notification.Name("talk9.message.statusFinalized")
    // Posted by CallsService when a call terminates with a non-zero PJSIP error code (ICE/TURN failure).
    static let callFailedWithICEError = Notification.Name("talk9.call.failedWithICEError")
    // Posted by ConversationsManager when daemon emits SwarmBootstrapFailed (all ICE candidates exhausted).
    static let swarmBootstrapFailed   = Notification.Name("talk9.swarm.bootstrapFailed")
}

#if DEBUG
extension Notification.Name {
    static let debugReRegisterFired    = Notification.Name("talk9.debug.reRegisterFired")
    static let debugForceReRegister    = Notification.Name("talk9.debug.forceReRegister")
    static let debugConversationError  = Notification.Name("talk9.debug.conversationError")
    static let debugDeviceAnnounced    = Notification.Name("talk9.debug.deviceAnnounced")
}
#endif
