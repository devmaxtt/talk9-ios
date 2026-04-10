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

struct WelcomeView: View, StateEmittingView {
    typealias StateEmitterType = StatePublisher<WalkthroughState>

    @StateObject var viewModel: WelcomeVM
    let notCancelable: Bool
    var stateEmitter = StatePublisher<WalkthroughState>()

    init(injectionBag: InjectionBag,
         notCancelable: Bool) {
        self.notCancelable = notCancelable
        _viewModel = StateObject(wrappedValue:
                                    WelcomeVM(with: injectionBag))
    }

    @Environment(\.verticalSizeClass)
    var verticalSizeClass

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Group {
                    if verticalSizeClass == .compact {
                        HorizontalView(model: viewModel,
                                       stateEmitter: stateEmitter)
                    } else {
                        PortraitView(model: viewModel,
                                     stateEmitter: stateEmitter)
                    }
                }
                .padding()
                alertView()
                    .ignoresSafeArea()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                cancelButton()
                Spacer()
            }
            .padding(.horizontal)
        }
        .applyJamiBackground()
    }

    @ViewBuilder
    func alertView() -> some View {
        switch viewModel.creationState {
        case .initial, .unknown, .success:
            EmptyView()
        case .started:
            loadingView()
        case .timeOut:
            timeOutAlert()
        case .nameNotRegistered:
            registrationErrorAlert()
        case .error(let error):
            accountCreationErrorAlert(error: error)
        }
    }

    @ViewBuilder
    func accountCreationErrorAlert(error: AccountCreationError) -> some View {
        CustomAlert(content: { AlertFactory
            .alertWithOkButton(title: error.title,
                               message: error.message,
                               action: { [weak viewModel] in
                                guard let viewModel = viewModel else { return }
                                viewModel.creationState = .initial
                               })
        })
    }

    @ViewBuilder
    func registrationErrorAlert() -> some View {
        let title = L10n.CreateAccount.usernameNotRegisteredTitle
        let message = L10n.CreateAccount.usernameNotRegisteredMessage
        CustomAlert(content: { AlertFactory
            .alertWithOkButton(title: title,
                               message: message,
                               action: {[weak viewModel, weak stateEmitter] in
                                guard let viewModel = viewModel,
                                      let stateEmitter = stateEmitter else { return }
                                viewModel.finish(stateHandler: stateEmitter)
                               })
        })
    }

    @ViewBuilder
    func timeOutAlert() -> some View {
        let title = L10n.CreateAccount.timeoutTitle
        let message = L10n.CreateAccount.timeoutMessage
        CustomAlert(content: { AlertFactory
            .alertWithOkButton(title: title,
                               message: message,
                               action: {[weak viewModel, weak stateEmitter] in
                                guard let viewModel = viewModel,
                                      let stateEmitter = stateEmitter else { return }
                                viewModel.finish(stateHandler: stateEmitter)
                               })
        })
    }

    @ViewBuilder
    func loadingView() -> some View {
        CustomAlert(content: { AlertFactory.createLoadingView() })
    }

    @ViewBuilder
    func cancelButton() -> some View {
        if notCancelable {
            EmptyView()
        } else {
            Button(action: { [weak viewModel, weak stateEmitter] in
                guard let viewModel = viewModel,
                      let stateEmitter = stateEmitter else { return }
                viewModel.finish(stateHandler: stateEmitter)
            }, label: {
                Text(L10n.Global.cancel)
                    .foregroundColor(Color.jamiColor)
            })
        }
    }
}
struct HorizontalView: View {
    var model: WelcomeVM
    let stateEmitter: StatePublisher<WalkthroughState>
    @SwiftUI.State private var height: CGFloat = 1
    var body: some View {
        HStack(spacing: 30) {
            VStack {
                Spacer()
                HeaderView()
                Spacer()
            }
            VStack {
                Spacer()
                ScrollView(showsIndicators: false) {
                    ButtonsView(model: model,
                                stateEmitter: stateEmitter)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        height = proxy.size.height
                                    }
                            }
                        )
                }
                .frame(height: height + 10)
                Spacer()
            }
        }
    }
}

struct PortraitView: View {
    var model: WelcomeVM
    let stateEmitter: StatePublisher<WalkthroughState>
    var body: some View {
        VStack {
            Spacer(minLength: 80)
            HeaderView()
            ScrollView(showsIndicators: false) {
                ButtonsView(model: model,
                            stateEmitter: stateEmitter)
            }
        }
    }
}

struct HeaderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("jami_gnupackage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 70)
                .accessibilityHidden(true)
            Text("Welcome to Talk 9")
                .font(.title2.bold())
                .foregroundColor(.blue)
                .padding(.bottom, 8)
        }
    }
}

struct ButtonsView: View {
    var model: WelcomeVM
    let stateEmitter: StatePublisher<WalkthroughState>
    @SwiftUI.State private var showAdvancedLogin = false
    @SwiftUI.State private var username = ""
    @SwiftUI.State private var password = ""
    @Environment(\.colorScheme) var colorScheme

    private var isLoginDisabled: Bool {
        username.isEmpty || password.isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            // Username field with icon
            HStack(spacing: 10) {
                Image(systemName: "person")
                    .foregroundColor(Color(UIColor.secondaryLabel))
                WalkthroughTextEditView(text: $username,
                                        placeholder: L10n.Global.username,
                                        backgroundColor: .clear)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.4 : 0), lineWidth: 1)
            )

            // Password field with icon
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .foregroundColor(Color(UIColor.secondaryLabel))
                WalkthroughPasswordView(text: $password,
                                        placeholder: L10n.Global.password,
                                        backgroundColor: .clear)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.4 : 0), lineWidth: 1)
            )

            // Reset Password link
            HStack {
                Spacer()
                Button("Reset Password") {[weak model, weak stateEmitter] in
                    guard let model = model,
                          let stateEmitter = stateEmitter else { return }
                    model.openResetPassword(stateHandler: stateEmitter)
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            // Sign In button
            Button(action: {[weak model, weak stateEmitter] in
                guard let model = model,
                      let stateEmitter = stateEmitter else { return }
                model.loginWithJAMS(username: username,
                                    password: password,
                                    stateHandler: stateEmitter)
            }) {
                Text("Sign In")
                    .fontWeight(.semibold)
                    .padding(14)
                    .frame(maxWidth: 500)
                    .background(Color(UIColor.jamiButtonDark).opacity(isLoginDisabled ? 0.5 : 1.0))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(isLoginDisabled)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 4)

            // Advanced Login toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showAdvancedLogin.toggle()
                }
            }) {
                HStack {
                    Text("Advanced Login")
                        .font(.subheadline)
                        .foregroundColor(Color.white.opacity(0.8))
                    Spacer()
                    Image(systemName: showAdvancedLogin ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .foregroundColor(Color.white.opacity(0.8))
                }
            }

            if showAdvancedLogin {
                expandedButton(L10n.Welcome.linkDevice,
                               icon: "laptopcomputer.and.iphone",
                               action: {[weak model, weak stateEmitter] in
                    guard let model = model,
                          let stateEmitter = stateEmitter else { return }
                    model.openLinkDevice(stateHandler: stateEmitter)
                })
                expandedButton(L10n.Welcome.linkBackup,
                               icon: "arrow.up.doc",
                               action: {[weak model, weak stateEmitter] in
                    guard let model = model,
                          let stateEmitter = stateEmitter else { return }
                    model.openImportArchive(stateHandler: stateEmitter)
                })
            }

            // Register now
            HStack(spacing: 4) {
                Text("No account?")
                    .foregroundColor(Color.white.opacity(0.75))
                Button("Register now") {[weak model, weak stateEmitter] in
                    guard let model = model,
                          let stateEmitter = stateEmitter else { return }
                    model.openRegister(stateHandler: stateEmitter)
                }
                .font(.subheadline.bold())
                .foregroundColor(.blue)
            }
            .font(.subheadline)
        }
    }

    private func expandedButton(_ title: String,
                                 icon: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
                    .fontWeight(.medium)
            }
            .foregroundColor(.blue)
            .padding(14)
            .frame(maxWidth: 500)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            )
            .cornerRadius(12)
        }
    }
}

extension View {
    func applyJamiBackground() -> some View {
        self.background(
            Image("background_login")
                .resizable()
                .ignoresSafeArea()
                .scaledToFill()
                .accessibilityIdentifier(AccessibilityIdentifiers.welcomeWindow)
                .accessibilityHidden(true)
        )
    }
}
