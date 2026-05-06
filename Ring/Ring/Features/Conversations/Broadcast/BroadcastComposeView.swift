/*
 * Copyright (C) 2026 Talk9
 */

import SwiftUI

struct BroadcastComposeView: View {

    @ObservedObject var viewModel: BroadcastViewModel
    @SwiftUI.State private var messageText = ""
    @SwiftUI.State private var recipientsExpanded = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                recipientsHeader
                Divider()
                Spacer()
                inputBar
            }
            if viewModel.sendSuccess {
                successToast
            }
        }
        .navigationTitle("Compose")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Success Toast

    private var successToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Message sent!")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(25)
            .shadow(color: .black.opacity(0.15), radius: 8)
            .padding(.bottom, 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: viewModel.sendSuccess)
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
            ZStack(alignment: .topLeading) {
                if messageText.isEmpty {
                    Text("Write message")
                        .foregroundColor(Color(.placeholderText))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $messageText)
                    .frame(minHeight: 36, maxHeight: 120)
                    .opacity(messageText.isEmpty ? 0.85 : 1)
            }
            .padding(8)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            )

            if viewModel.isSending {
                SwiftUI.ProgressView()
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
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || viewModel.sendSuccess)
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
