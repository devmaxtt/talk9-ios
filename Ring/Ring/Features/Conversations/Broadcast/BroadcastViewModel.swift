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
    @Published var selected: Set<String> = []
    @Published var searchText = ""
    @Published var isSending = false
    @Published var sendSuccess = false
    @Published var limitReached = false

    var onSendSuccess: (() -> Void)?

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
                        let name = self.resolveName(jamiId: participant.jamiId,
                                                    accountId: conversation.accountId,
                                                    conversationHash: conversation.hash)
                        return BroadcastContact(id: conversation.id,
                                                conversation: conversation,
                                                displayName: name)
                    }
                    .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

                // Async lookup for contacts still showing as ID
                self.lookupUnresolvedNames()
            })
            .disposed(by: disposeBag)
    }

    // Priority: profile alias → registered username → conversation hash → jamiId prefix
    private func resolveName(jamiId: String, accountId: String, conversationHash: String) -> String {
        let uri = "ring:" + jamiId
        if let alias = injectionBag.contactsService.getProfile(uri: uri, accountId: accountId)?.alias,
           !alias.isEmpty {
            return alias
        }
        if let userName = injectionBag.contactsService.contact(withHash: jamiId)?.userName,
           !userName.isEmpty {
            return userName
        }
        if !conversationHash.isEmpty {
            return conversationHash
        }
        return String(jamiId.prefix(16))
    }

    // For contacts whose name looks like a raw hash, trigger a nameserver lookup
    private func lookupUnresolvedNames() {
        let unresolved = contacts.filter { isLikelyId($0.displayName) }
        guard !unresolved.isEmpty else { return }

        // Subscribe once to catch all lookup responses
        injectionBag.nameService
            .usernameLookupStatus
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] response in
                guard let self = self,
                      let name = response.name, !name.isEmpty,
                      let requestedId = response.requestedName else { return }
                // Update matching contact
                if let idx = self.contacts.firstIndex(where: {
                    $0.conversation.getParticipants().first?.jamiId == requestedId
                }) {
                    self.contacts[idx].displayName = name
                    self.contacts.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
                }
            })
            .disposed(by: disposeBag)

        for contact in unresolved {
            guard let jamiId = contact.conversation.getParticipants().first?.jamiId else { continue }
            injectionBag.nameService.lookupAddress(
                withAccount: contact.conversation.accountId,
                nameserver: "",
                address: jamiId
            )
        }
    }

    // A display name that looks like a raw jamiId (hex, 16+ chars, no spaces)
    private func isLikelyId(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 16 else { return false }
        return trimmed.allSatisfy { $0.isHexDigit }
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
            guard let self = self else { return }
            self.isSending = false
            self.sendSuccess = true
            // Navigate back after showing success briefly
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.onSendSuccess?()
            }
        }
    }
}
