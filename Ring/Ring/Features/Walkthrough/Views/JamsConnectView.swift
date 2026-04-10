/*
 *  Copyright (C) 2024 Savoir-faire Linux Inc.
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

import SwiftUI

struct JamsConnectView: View {
    @StateObject var viewModel: ConnectToManagerVM
    let dismissHandler = DismissHandler()

    init(injectionBag: InjectionBag,
         connectAction: @escaping (_ username: String, _ password: String, _ server: String, _ responseLog: @escaping (String) -> Void) -> Void) {
        _viewModel = StateObject(wrappedValue:
                                    ConnectToManagerVM(with: injectionBag,
                                                       connectAction: connectAction))
    }

    var body: some View {
        VStack {
            header
            ScrollView(showsIndicators: false) {
                Text(L10n.LinkToAccountManager.jamsExplanation)
                    .multilineTextAlignment(.center)
                    .padding(.vertical)
                serverView
                Text(L10n.LinkToAccountManager.enterCredentials)
                    .padding(.vertical)
                usernameView
                passwordView
            }
            .padding(.horizontal)
            .frame(maxWidth: 500)

            if !viewModel.debugLogs.isEmpty {
                debugPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.debugLogs.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea()
        )
    }

    private var header: some View {
        ZStack {
            HStack {
                cancelButton
                Spacer()
                signinButton
            }
            Text(L10n.LinkToAccountManager.title)
                .font(.headline)
        }
        .padding()
    }

    private var cancelButton: some View {
        Button(action: {[weak dismissHandler] in
            dismissHandler?.dismissView()
        }, label: {
            Text(L10n.Global.cancel)
                .foregroundColor(Color(UIColor.label))
        })
    }

    private var signinButton: some View {
        Button(action: {[weak dismissHandler, weak viewModel] in
            dismissHandler?.dismissView()
            viewModel?.connect()
        }, label: {
            Text(L10n.LinkToAccountManager.signIn)
                .foregroundColor(viewModel.signInButtonColor)
        })
        .disabled(viewModel.isSignInDisabled)
    }

    private var usernameView: some View {
        WalkthroughTextEditView(text: $viewModel.username,
                                placeholder: L10n.Global.username)
    }

    private var serverView: some View {
        let placeholder = L10n.LinkToAccountManager.accountManagerPlaceholder
        return WalkthroughFocusableTextView(text: $viewModel.server,
                                            isTextFieldFocused: $viewModel.isTextFieldFocused,
                                            placeholder: placeholder)
    }

    private var passwordView: some View {
        WalkthroughPasswordView(text: $viewModel.password,
                                placeholder: L10n.Global.password)
            .padding(.bottom)
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row with clear button
            HStack {
                Text("Debug Log")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    viewModel.debugLogs.removeAll()
                    viewModel.filterText = ""
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Keyword filter field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Filter keyword...", text: $viewModel.filterText)
                    .font(.caption)
                    .autocorrectionDisabled()
                if !viewModel.filterText.isEmpty {
                    Button(action: { viewModel.filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .padding(6)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(8)

            // Log entries list
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.filteredLogs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.type.label)
                                    .font(.caption.bold())
                                    .foregroundColor(entry.type.color)
                                Spacer()
                                Text(entry.formattedTime)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.content)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
