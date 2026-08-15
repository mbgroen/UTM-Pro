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

import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// How to authenticate to the server.
///
/// Note that RSA keys are not supported: the underlying SSH implementation
/// offers Ed25519, ECDSA (P256/P384/P521) and Secure Enclave P256 only. A host
/// that accepts only `ssh-rsa` needs either a password or a newly installed
/// Ed25519 key.
public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(SSHPrivateKey)
}

/// A private key usable for SSH public-key authentication.
public struct SSHPrivateKey: Sendable {
    let nioKey: NIOSSHPrivateKey

    /// The matching public key in `authorized_keys` form, ready to be
    /// installed on the server.
    public let openSSHPublicKey: String

    /// The raw Ed25519 seed, kept so the key can be written back out in
    /// OpenSSH format for storage. `NIOSSHPrivateKey` does not expose its key
    /// material, and nil for every other key type.
    let ed25519Seed: Data?

    public init(ed25519 key: Curve25519.Signing.PrivateKey, comment: String = "") {
        self.nioKey = NIOSSHPrivateKey(ed25519Key: key)
        self.openSSHPublicKey = Self.authorizedKeyLine(for: self.nioKey.publicKey, comment: comment)
        self.ed25519Seed = key.rawRepresentation
    }

    public init(p256 key: P256.Signing.PrivateKey, comment: String = "") {
        self.nioKey = NIOSSHPrivateKey(p256Key: key)
        self.openSSHPublicKey = Self.authorizedKeyLine(for: self.nioKey.publicKey, comment: comment)
        self.ed25519Seed = nil
    }

    /// A key held in the Secure Enclave.
    ///
    /// The private half never leaves the enclave, so it cannot be copied off
    /// the device the way a key file can.
    public init(secureEnclave key: SecureEnclave.P256.Signing.PrivateKey, comment: String = "") {
        self.nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        self.openSSHPublicKey = Self.authorizedKeyLine(for: self.nioKey.publicKey, comment: comment)
        // Never exportable: the private half stays in the enclave.
        self.ed25519Seed = nil
    }

    private static func authorizedKeyLine(for publicKey: NIOSSHPublicKey, comment: String) -> String {
        let line = String(openSSHPublicKey: publicKey)
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : "\(line) \(trimmed)"
    }
}

/// Offers a single credential, once.
///
/// If the server rejects it we stop rather than cycling methods, so a wrong
/// password surfaces as an error instead of burning through the server's
/// authentication attempt budget.
final class SSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let credential: SSHCredential
    private let lock = NSLock()
    private var offered = false
    private var _wasRejected = false

    /// True once the server has asked for another credential after we made
    /// our offer, which is how a rejection reaches the client.
    ///
    /// Without this, declining to offer anything further closes the
    /// connection cleanly and the failure is indistinguishable from the
    /// network dropping.
    var wasRejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _wasRejected
    }

    init(username: String, credential: SSHCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        lock.lock()
        let hasOffered = offered
        if hasOffered {
            _wasRejected = true
        }
        offered = true
        lock.unlock()

        guard !hasOffered else {
            // We already tried; signal that we have nothing further to offer.
            nextChallengePromise.succeed(nil)
            return
        }

        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHError.authenticationFailed)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username,
                                              serviceName: "",
                                              offer: .password(.init(password: password)))
            )
        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHError.authenticationFailed)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username,
                                              serviceName: "",
                                              offer: .privateKey(.init(privateKey: key.nioKey)))
            )
        }
    }
}
