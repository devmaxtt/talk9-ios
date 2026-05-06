/*
 * Copyright (C) 2026 Talk9
 */

import Foundation
import RxSwift
import RxRelay

struct BroadcastContact: Identifiable {
    let id: String            // conversation ID
    let conversation: ConversationModel
    var displayName: String
}

class BroadcastViewModel: ObservableObject {

    static let maxRecipients = 50

    @Published var contacts: [BroadcastContact] = []
    @Published var selected: Set<String> = []  // conversation IDs
    @Published var searchText = ""
    @Published var isSending = false
    @Published var sendSuccess = false
    @Published var limitReached = false

    private let injectionBag: InjectionBag
    private var disposeBag = DisposeBag()

    init(injectionBag: InjectionBag) {
        self.injectionBag = injectionBag
        loadContacts()
    }

    // MARK: - Contact loading

    private func loadContacts() {
        injectionBag.conversationsService.conversations
            .asObservable()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] conversations in
                guard let self = self else { return }
                self.contacts = conversations
                    .filter { $0.isCoredialog() }
                    .compactMap { conversation -> BroadcastContact? in
                        guard let participant = conversation.getParticipants().first,
                              !participant.jamiId.isEmpty else { return nil }
                        let name = conversation.hash.isEmpty ? participant.jamiId : conversation.hash
                        return BroadcastContact(id: conversation.id,
                                                conversation: conversation,
                                                displayName: name)
                    }
                    .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            })
            .disposed(by: disposeBag)
    }

    // MARK: - Filtering

    var filteredContacts: [BroadcastContact] {
        guard !searchText.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.lowercased().contains(searchText.lowercased())
        }
    }

    var selectedContacts: [BroadcastContact] {
        contacts.filter { selected.contains($0.id) }
    }

    // MARK: - Selection

    func toggleSelection(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
            limitReached = false
        } else {
            guard selected.count < Self.maxRecipients else {
                limitReached = true
                return
            }
            selected.insert(id)
            limitReached = selected.count >= Self.maxRecipients
        }
    }

    func selectAll() {
        if selected.count == filteredContacts.count {
            selected.removeAll()
            limitReached = false
        } else {
            let toSelect = filteredContacts.prefix(Self.maxRecipients).map { $0.id }
            selected = Set(toSelect)
            limitReached = selected.count >= Self.maxRecipients
        }
    }

    // MARK: - Send

    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        let targets = selectedContacts
        let group = DispatchGroup()

        for contact in targets {
            let conversation = contact.conversation
            if conversation.type == .nonSwarm {
                guard let participant = conversation.getParticipants().first,
                      let account = injectionBag.accountService.currentAccount else { continue }
                group.enter()
                _ = injectionBag.conversationsService
                    .sendNonSwarmMessage(withContent: text, from: account, jamiId: participant.jamiId)
                    .subscribe(onCompleted: { group.leave() },
                               onError: { _ in group.leave() })
            } else {
                injectionBag.conversationsService.sendSwarmMessage(
                    conversationId: conversation.id,
                    accountId: conversation.accountId,
                    message: text,
                    parentId: ""
                )
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isSending = false
            self?.sendSuccess = true
        }
    }
}
