/*
 * Copyright (C) 2026 Talk9
 */

import SwiftUI

// MARK: - Screen 1: Contact Picker

struct BroadcastContactPickerView: View {

    @ObservedObject var viewModel: BroadcastViewModel
    @SwiftUI.State private var showCompose = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                selectAllRow
                Divider()
                contactList
                if !viewModel.selected.isEmpty {
                    nextButton
                }
            }
            .navigationTitle("Broadcast Message")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $viewModel.limitReached) {
                Alert(
                    title: Text("Recipient limit reached"),
                    message: Text("You can select up to \(BroadcastViewModel.maxRecipients) contacts."),
                    dismissButton: .default(Text("OK")) { viewModel.limitReached = false }
                )
            }
            .background(
                NavigationLink(destination: BroadcastComposeView(viewModel: viewModel),
                               isActive: $showCompose) { EmptyView() }
            )
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search contacts", text: $viewModel.searchText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Select All

    private var selectAllRow: some View {
        let filtered = viewModel.filteredContacts
        let allSelected = !filtered.isEmpty && filtered.allSatisfy { viewModel.selected.contains($0.id) }
        let someSelected = !viewModel.selected.isEmpty && !allSelected
        return Button(action: { viewModel.selectAll() }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if allSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.accentColor)
                    } else if someSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 2)
                    }
                }
                Text("Select All")
                    .foregroundColor(.primary)
                Spacer()
                Text("\(viewModel.selected.count)/\(BroadcastViewModel.maxRecipients)")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: Contact List

    private var contactList: some View {
        List(viewModel.filteredContacts) { contact in
            Button(action: { viewModel.toggleSelection(contact.id) }) {
                HStack(spacing: 12) {
                    BroadcastAvatarView(name: contact.displayName, size: 44)
                    Text(contact.displayName)
                        .foregroundColor(.primary)
                    Spacer()
                    if viewModel.selected.contains(contact.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.title3)
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.secondary)
                            .font(.title3)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
    }

    // MARK: Next Button

    private var nextButton: some View {
        Button(action: { showCompose = true }) {
            Text("Next (\(viewModel.selected.count))")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Reusable Avatar

struct BroadcastAvatarView: View {
    let name: String
    let size: CGFloat

    private var initials: String {
        let words = name.split(separator: " ").map(String.init)
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        let hash = abs(name.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .red, .pink, .yellow, .gray]
        return colors[hash % colors.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
            Text(initials)
                .foregroundColor(.white)
                .font(.system(size: size * 0.38, weight: .semibold))
        }
    }
}
