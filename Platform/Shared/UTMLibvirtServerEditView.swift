//
// Copyright © 2026 UTM Pro contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import LibvirtKit
import SwiftUI

/// Add or edit a remote libvirt host.
///
/// The form is ordered by what the user must decide, not by what the struct
/// stores: where the server is, how to prove who they are, then options that
/// have sensible defaults. Key generation is offered first because installing
/// a key is the step most likely to go wrong, and doing it here means the user
/// never has to find out afterwards that their existing RSA key is unusable.
@available(iOS 16, macOS 13, *)
struct UTMLibvirtServerEditView: View {
    @Binding var settings: UTMLibvirtServerSettings

    /// Called with the finished settings and the secret to store.
    let onSave: (UTMLibvirtServerSettings, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var secret: String = ""
    @State private var generatedKey: SSHPrivateKey?
    @State private var testState: TestState = .idle
    @State private var showAdvanced: Bool = false

    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded(String)
        case failed(String)
    }

    private var isValid: Bool {
        !settings.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            connectionSection
            authenticationSection
            if generatedKey != nil || settings.authenticationKind == .privateKey {
                keyInstallSection
            }
            advancedSection
            testSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(settings, secret.isEmpty ? nil : secret)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }

    // MARK: - Where

    private var connectionSection: some View {
        Section {
            TextField("Address", text: $settings.host, prompt: Text("nas.local"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("Username", text: $settings.username, prompt: Text("root"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("Name", text: $settings.label,
                      prompt: Text(settings.host.isEmpty ? "Optional" : settings.host))
        } header: {
            Text("Server")
        } footer: {
            Text("The account needs permission to reach libvirt on the host.")
        }
    }

    // MARK: - How to authenticate

    private var authenticationSection: some View {
        Section {
            Picker("Authenticate With", selection: $settings.authenticationKind) {
                Text("SSH Key").tag(UTMLibvirtServerSettings.AuthenticationKind.privateKey)
                Text("Password").tag(UTMLibvirtServerSettings.AuthenticationKind.password)
            }
            .pickerStyle(.segmented)

            switch settings.authenticationKind {
            case .password:
                SecureField("Password", text: $secret)
            case .privateKey:
                if generatedKey == nil {
                    Button {
                        generateKey()
                    } label: {
                        Label("Generate a New Key", systemImage: "key.horizontal")
                    }
                    Text("Or paste an existing private key below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $secret)
                        .font(.caption.monospaced())
                        .frame(minHeight: 80)
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            if settings.authenticationKind == .privateKey {
                // Stated up front rather than after a failed connection: an
                // RSA key is the most likely thing a user already has.
                Text("Ed25519 and ECDSA keys are supported. RSA keys are not — generate a key here if that is all you have.")
            } else {
                Text("The password is stored in your Keychain and never leaves this device except to authenticate.")
            }
        }
    }

    /// Shown once a key exists, because the key is useless until its public
    /// half is on the server. The command is spelled out so the user does not
    /// have to know the syntax.
    @ViewBuilder private var keyInstallSection: some View {
        if let key = generatedKey {
            Section {
                Text(key.openSSHPublicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyToPasteboard(key.openSSHPublicKey)
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }

                Text("Add it to `~/.ssh/authorized_keys` for \(settings.username.isEmpty ? "the account" : settings.username) on \(settings.host.isEmpty ? "the server" : settings.host), then test the connection below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Install This Key on the Server")
            } footer: {
                Text("If you use ssh-copy-id and it reports the key already exists, pass -f. It decides by logging in, so an existing key that already works makes it skip the new one.")
            }
        }
    }

    // MARK: - Options with defaults

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Toggle("Tunnel Console Through SSH", isOn: $settings.tunnelConsole)
                Text("Sends console traffic over the SSH connection instead of connecting to the host's console port directly. Leave this on unless the console port is already protected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Port") {
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                TextField("libvirt URI", text: $settings.uri, prompt: Text("qemu:///system"))
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                if let fingerprint = settings.hostKeyFingerprint {
                    LabeledContent("Trusted Host Key") {
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(role: .destructive) {
                        settings.hostKeyFingerprint = nil
                    } label: {
                        Text("Forget Host Key")
                    }
                }
            }
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                if testState == .testing {
                    Label("Testing…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                }
            }
            .disabled(!isValid || testState == .testing || secretForTest == nil)

            switch testState {
            case .succeeded(let detail):
                Label {
                    Text(detail).font(.caption)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
            case .failed(let message):
                Label {
                    Text(message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
            case .idle, .testing:
                EmptyView()
            }
        } footer: {
            Text("Testing connects once and reads the host's details. It changes nothing on the server.")
        }
    }

    // MARK: - Actions

    private func generateKey() {
        let key = SSHPrivateKey.generateEd25519(comment: "UTM Pro (\(settings.host))")
        generatedKey = key
        // The private half is held only until save, when it goes to the
        // Keychain.
        secret = key.privateKeyStorageRepresentation
    }

    private var secretForTest: String? {
        secret.isEmpty ? UTMLibvirtCredentialStore.secret(for: settings.id) : secret
    }

    private func testConnection() async {
        guard let secretForTest else { return }
        testState = .testing
        do {
            let credential: SSHCredential
            switch settings.authenticationKind {
            case .password:
                credential = .password(secretForTest)
            case .privateKey:
                credential = .privateKey(try SSHPrivateKey(openSSHPrivateKey: secretForTest))
            }
            let policy: SSHHostKeyPolicy
            if let fingerprint = settings.hostKeyFingerprint {
                policy = .pinned(SSHHostKeyFingerprint(value: fingerprint))
            } else {
                policy = .trustOnFirstUse
            }
            let destination = SSHDestination(host: settings.host,
                                             port: settings.port,
                                             username: settings.username,
                                             credential: credential,
                                             hostKeyPolicy: policy)
            let connection = SSHConnection(destination: destination)
            try await connection.connect()
            if settings.hostKeyFingerprint == nil,
               let presented = await connection.presentedHostKey {
                settings.hostKeyFingerprint = presented.value
            }
            let host = LibvirtHost(connection: connection, uri: settings.uri)
            try await host.checkAvailability()
            let domains = try await host.listDomains()
            let info = try? await host.hostInfo()
            await connection.disconnect()

            let name = info?.hostname ?? settings.host
            testState = .succeeded(String(format: NSLocalizedString("Connected to %@ — %d virtual machines.", comment: "UTMLibvirtServerEditView"),
                                          name, domains.count))
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
