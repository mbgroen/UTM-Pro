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

/// The SHA256 fingerprint of a server host key, in the `SHA256:base64` form
/// that OpenSSH prints, so the user can compare it against `ssh-keyscan`
/// output without converting anything.
public struct SSHHostKeyFingerprint: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    init(publicKey: NIOSSHPublicKey) {
        // `String(openSSHPublicKey:)` yields the `<algorithm> <base64 blob>`
        // authorized_keys form. The blob is the same wire encoding that
        // `ssh-keygen -lf` hashes, so fingerprints computed here compare
        // directly against what OpenSSH prints.
        let openSSH = String(openSSHPublicKey: publicKey)
        let blob = openSSH.split(separator: " ").dropFirst().first.flatMap {
            Data(base64Encoded: String($0))
        }
        let digest = SHA256.hash(data: blob ?? Data(openSSH.utf8))
        // OpenSSH prints the base64 without padding.
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        self.value = "SHA256:\(base64)"
    }

    public var description: String { value }
}

/// How to treat the host key a server presents.
public enum SSHHostKeyPolicy: Sendable {
    /// Require the key to match this fingerprint. Anything else fails the
    /// connection.
    case pinned(SSHHostKeyFingerprint)

    /// Accept whatever the server presents and report it, so the caller can
    /// pin it for next time.
    ///
    /// Only appropriate for the very first connection to a host, where the
    /// user is shown the fingerprint and accepts it. Never use this for
    /// subsequent connections: it would silently accept a substituted host.
    case trustOnFirstUse
}

/// Validates the server's host key against a policy, and records what it saw.
final class SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let policy: SSHHostKeyPolicy
    private let lock = NSLock()
    private var _observedFingerprint: SSHHostKeyFingerprint?

    /// The fingerprint the server actually presented, once known.
    var observedFingerprint: SSHHostKeyFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return _observedFingerprint
    }

    init(policy: SSHHostKeyPolicy) {
        self.policy = policy
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHHostKeyFingerprint(publicKey: hostKey)
        lock.lock()
        _observedFingerprint = fingerprint
        lock.unlock()

        switch policy {
        case .trustOnFirstUse:
            validationCompletePromise.succeed(())
        case .pinned(let expected):
            if expected == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyMismatch(expected: expected.value,
                                                                       actual: fingerprint.value))
            }
        }
    }
}
