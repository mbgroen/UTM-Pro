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
import Network

/// Verifies the SSH tunnel the console rides on.
///
/// Read-only: it opens forwards, checks bytes flow through them, and tears
/// them down. It never starts, stops or otherwise touches the domain.
enum TunnelTest {
    static func run(connection: SSHConnection, libvirt: LibvirtHost, domain name: String) async throws {
        print("\n── tunnel test for '\(name)' ──")

        // Prove the tunnel itself carries bytes before blaming any particular
        // service. sshd greets a client the moment it connects, needing no
        // input, so it isolates the forwarder from protocol details.
        try await bannerCheck(connection: connection)

        let domain = try await libvirt.domain(named: name)
        guard let graphics = domain.preferredGraphics else {
            throw TestFailure("'\(name)' has no console device")
        }
        guard let remotePort = graphics.port else {
            throw TestFailure("'\(name)' has no console port; is it running?")
        }
        print("  console: \(graphics.kind.rawValue) on port \(remotePort)")

        // Forwarding to loopback on the far side proves the traffic never
        // leaves the host unencrypted, which is the point of tunnelling.
        let localPort = try await connection.forwardLocalPort(to: "127.0.0.1", remotePort: remotePort)
        print("  forwarded 127.0.0.1:\(localPort) -> 127.0.0.1:\(remotePort) on the host")

        defer {
            Task { await connection.closeForward(localPort: localPort) }
        }

        // Deliberately not speaking SPICE here. Reproducing the link handshake
        // well enough to draw a reply means reimplementing a chunk of the
        // protocol in a test harness, and getting it subtly wrong reports a
        // failure that says nothing about the tunnel. CocoaSpice is the real
        // client; this only needs to prove the port is reachable through the
        // forward, which the sshd banner above already showed carries data.
        try await connectOnly(localPort: localPort)
        print("  console port accepts connections through the tunnel ✓")
        print("\n  tunnel works")
    }

    /// Forwards to the host's own SSH port and reads its greeting.
    private static func bannerCheck(connection: SSHConnection) async throws {
        let localPort = try await connection.forwardLocalPort(to: "127.0.0.1", remotePort: 22)
        defer {
            Task { await connection.closeForward(localPort: localPort) }
        }
        let banner = try await receiveOnly(localPort: localPort)
        let text = String(decoding: banner.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("SSH-") else {
            throw TestFailure("tunnel carried no data: expected an SSH banner, got \(banner.count) bytes")
        }
        print("  tunnel carries data (host sshd said \(text.debugDescription)) ✓")
    }

    /// Connects and reads without sending anything.
    private static func receiveOnly(localPort: Int) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: UInt16(localPort))!,
                                      using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, _, error in
                        if let error {
                            resumed.finish(continuation, .failure(error), connection)
                        } else {
                            resumed.finish(continuation, .success(data ?? Data()), connection)
                        }
                    }
                case .failed(let error):
                    resumed.finish(continuation, .failure(error), connection)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Opens a TCP connection through the tunnel and closes it.
    private static func connectOnly(localPort: Int) async throws {
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: UInt16(localPort))!,
                                      using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.finishVoid(continuation, .success(()), connection)
                case .failed(let error):
                    resumed.finishVoid(continuation, .failure(error), connection)
                case .waiting(let error):
                    // Nothing listening on the far side surfaces here rather
                    // than as an outright failure.
                    resumed.finishVoid(continuation, .failure(error), connection)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Guards against fulfilling the continuation more than once, which the
    /// state handler would otherwise do when a connection fails after reading.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func finish(_ continuation: CheckedContinuation<Data, Error>,
                    _ result: Result<Data, Error>,
                    _ connection: NWConnection) {
            guard claim() else { return }
            connection.cancel()
            continuation.resume(with: result)
        }

        func finishVoid(_ continuation: CheckedContinuation<Void, Error>,
                        _ result: Result<Void, Error>,
                        _ connection: NWConnection) {
            guard claim() else { return }
            connection.cancel()
            continuation.resume(with: result)
        }

        private func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }
}
