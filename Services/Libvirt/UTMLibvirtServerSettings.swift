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

import Foundation
import LibvirtKit
import Security

/// Everything about a saved libvirt host except its secret.
///
/// Stored in user defaults. The password or private key is kept in the
/// Keychain and referenced by this record's `id`.
struct UTMLibvirtServerSettings: Codable, Identifiable, Hashable {
    var id: UUID = UUID()

    /// Display name in the sidebar. Defaults to the host name.
    var label: String = ""

    var host: String = ""

    var port: Int = 22

    var username: String = "root"

    /// libvirt URI on the far side. `qemu:///system` is what the
    /// OpenMediaVault KVM plugin manages.
    var uri: String = "qemu:///system"

    /// Which kind of secret to look for in the Keychain.
    var authenticationKind: AuthenticationKind = .privateKey

    /// The host key we pinned on first connect.
    ///
    /// Absent means the host has not been trusted yet, and connecting will
    /// present the fingerprint for confirmation.
    var hostKeyFingerprint: String?

    /// Route the console through the SSH connection instead of connecting to
    /// the host's console port directly.
    ///
    /// On by default: these consoles are frequently exposed on every interface
    /// with no password, and tunnelling means the display never crosses the
    /// network in the clear.
    var tunnelConsole: Bool = true

    enum AuthenticationKind: String, Codable, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }
    }

    var displayName: String {
        label.isEmpty ? host : label
    }

    /// Host and port as shown to the user, hiding the default port.
    var addressDescription: String {
        port == 22 ? host : "\(host):\(port)"
    }
}

// MARK: - Keychain

/// Stores server secrets in the Keychain, keyed by server id.
///
/// Secrets never go into user defaults, and are not held in the settings
/// struct, so a settings value can be logged or encoded without leaking one.
enum UTMLibvirtCredentialStore {
    private static let service = "com.utmapp.UTM.libvirt"

    enum StoreError: Error, LocalizedError {
        case keychainFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychainFailed(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return String(format: NSLocalizedString("Keychain access failed: %@", comment: "UTMLibvirtCredentialStore"),
                              detail ?? "\(status)")
            }
        }
    }

    /// Stores a secret, replacing any existing one for this server.
    static func save(secret: String, for serverId: UUID) throws {
        let account = serverId.uuidString
        let data = Data(secret.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // The secret is only needed while the user is using the app, and
            // must not sync to other devices.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw StoreError.keychainFailed(insertStatus)
            }
        } else if status != errSecSuccess {
            throw StoreError.keychainFailed(status)
        }
    }

    static func secret(for serverId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for serverId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Builds the credential the transport needs from what is stored.
    static func credential(for settings: UTMLibvirtServerSettings) throws -> SSHCredential {
        guard let secret = secret(for: settings.id) else {
            throw UTMLibvirtServerError.credentialMissing
        }
        switch settings.authenticationKind {
        case .password:
            return .password(secret)
        case .privateKey:
            return .privateKey(try SSHPrivateKey(openSSHPrivateKey: secret))
        }
    }
}

enum UTMLibvirtServerError: Error {
    case credentialMissing
    case notConnected
    case hostKeyNotTrusted(fingerprint: String)
    case volumeMissingAfterCreate(String)
}

extension UTMLibvirtServerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .credentialMissing:
            return NSLocalizedString("No saved credential was found for this server. Edit the server to enter it again.", comment: "UTMLibvirtServer")
        case .notConnected:
            return NSLocalizedString("Not connected to this server.", comment: "UTMLibvirtServer")
        case .hostKeyNotTrusted(let fingerprint):
            return String(format: NSLocalizedString("The server presented host key %@, which has not been trusted yet.", comment: "UTMLibvirtServer"), fingerprint)
        case .volumeMissingAfterCreate(let name):
            return String(format: NSLocalizedString("The disk '%@' was created but the host did not list it afterwards, so the virtual machine was not defined.", comment: "UTMLibvirtServer"), name)
        }
    }
}
