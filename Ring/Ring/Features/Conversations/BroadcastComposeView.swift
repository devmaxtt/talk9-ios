/*
 * Copyright (C) 2026 Talk9
 */

import SwiftUI

// MARK: - Screen 2: Compose & Send

struct BroadcastComposeView: View {

    @ObservedObject var viewModel: BroadcastViewModel
    @SwiftUI.State private var messageText = ""
    @SwiftUI.State private var recipientsExpanded = false
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            recipientsHeader
            Divider()
            Spacer()
            inputBar
        }
        .navigationTitle("Compose")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.sendSuccess) { success in
            if success {
                // Pop back to root (SmartList)
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    // MARK: Recipients Header

    private var recipientsHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { recipientsExpanded.toggle() } }) {
                HStack {
                    Image(systemName: recipientsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Broadcasting to \(viewModel.selected.count) contacts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            if recipientsExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.selectedContacts) { contact in
                            HStack(spacing: 10) {
                                BroadcastAvatarView(name: contact.displayName, size: 36)
                                Text(contact.displayName)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 200)
                Divider()
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Message Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Write message", text: $messageText, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(20)
            if viewModel.isSending {
                ProgressView()
                    .padding(10)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          ? "arrow.up.circle"
                          : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? .secondary : .accentColor)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.06), radius: 4, y: -2)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        viewModel.sendMessage(text)
    }
}
