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

/// Errors raised by the SSH transport.
public enum SSHError: Error, Sendable, Equatable {
    /// The connection was not established, or was closed underneath us.
    case notConnected

    /// The TCP connection could not be established.
    case connectFailed(String)

    /// The server rejected every authentication method we offered.
    case authenticationFailed

    /// The server presented a host key that does not match the pinned one.
    ///
    /// This is never recoverable in-band: it is either a changed host or an
    /// interception. The user must explicitly re-pin.
    case hostKeyMismatch(expected: String, actual: String)

    /// The server presented a host key and we have no policy to evaluate it.
    case hostKeyUnknown(fingerprint: String)

    /// The remote command could not be started.
    case execFailed(String)

    /// The remote command ran but exited non-zero.
    case commandFailed(command: String, status: Int32, stderr: String)

    /// A local listening socket for a port forward could not be opened.
    case portForwardFailed(String)

    /// The operation did not complete within its deadline.
    case timedOut
}

extension SSHError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return NSLocalizedString("Not connected to the server.", comment: "SSHError")
        case .connectFailed(let reason):
            return String(format: NSLocalizedString("Could not connect: %@", comment: "SSHError"), reason)
        case .authenticationFailed:
            return NSLocalizedString("The server rejected the credentials.", comment: "SSHError")
        case .hostKeyMismatch(let expected, let actual):
            return String(format: NSLocalizedString("The server's host key changed. Expected %@ but got %@. This could mean the host was rebuilt, or that the connection is being intercepted.", comment: "SSHError"), expected, actual)
        case .hostKeyUnknown(let fingerprint):
            return String(format: NSLocalizedString("The server's host key (%@) is not trusted yet.", comment: "SSHError"), fingerprint)
        case .execFailed(let reason):
            return String(format: NSLocalizedString("Could not run the remote command: %@", comment: "SSHError"), reason)
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return String(format: NSLocalizedString("`%@` failed with status %d.", comment: "SSHError"), command, Int(status))
            } else {
                return String(format: NSLocalizedString("`%@` failed with status %d: %@", comment: "SSHError"), command, Int(status), detail)
            }
        case .portForwardFailed(let reason):
            return String(format: NSLocalizedString("Could not open the port forward: %@", comment: "SSHError"), reason)
        case .timedOut:
            return NSLocalizedString("The operation timed out.", comment: "SSHError")
        }
    }
}
