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
import NIOCore
import NIOPosix
import NIOSSH

/// Where and how to reach a host over SSH.
public struct SSHDestination: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    public var hostKeyPolicy: SSHHostKeyPolicy
    public var connectTimeout: TimeAmount

    public init(host: String,
                port: Int = 22,
                username: String,
                credential: SSHCredential,
                hostKeyPolicy: SSHHostKeyPolicy,
                connectTimeout: TimeAmount = .seconds(15)) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = connectTimeout
    }
}

/// A live SSH connection to one host.
///
/// Commands run on their own session channels over this single connection, so
/// listing twenty domains costs one TCP handshake and one key exchange rather
/// than twenty.
public actor SSHConnection {
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var channel: Channel?
    private var hostKeyValidator: SSHHostKeyValidator?
    private var forwarders: [SSHPortForwarder] = []

    public let destination: SSHDestination

    /// The host key the server presented on the current connection.
    ///
    /// After a trust-on-first-use connect, persist this and pin it for
    /// subsequent connections.
    public private(set) var presentedHostKey: SSHHostKeyFingerprint?

    public var isConnected: Bool {
        channel?.isActive ?? false
    }

    public init(destination: SSHDestination, group: EventLoopGroup? = nil) {
        self.destination = destination
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    deinit {
        try? channel?.close().wait()
        if ownsGroup {
            try? group.syncShutdownGracefully()
        }
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !isConnected else { return }

        let validator = SSHHostKeyValidator(policy: destination.hostKeyPolicy)
        let authenticator = SSHAuthenticationDelegate(username: destination.username,
                                                      credential: destination.credential)
        hostKeyValidator = validator

        // `connect` completes as soon as the TCP connection is up, which is
        // well before the SSH transport has finished key exchange and user
        // authentication. Opening a channel in that window fails, so we wait
        // for the authentication event before reporting success.
        let authenticated = group.next().makePromise(of: Void.self)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(destination.connectTimeout)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authenticator,
                                            serverAuthDelegate: validator)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    SSHAuthenticationWaiter(promise: authenticated),
                ])
            }

        do {
            let channel = try await bootstrap.connect(host: destination.host,
                                                      port: destination.port).get()
            self.presentedHostKey = validator.observedFingerprint
            do {
                try await authenticated.futureResult.get()
            } catch {
                try? await channel.close().get()
                // A rejected credential tears the connection down, which
                // otherwise reads as a plain disconnect. Report the real cause.
                if authenticator.wasRejected {
                    throw SSHError.authenticationFailed
                }
                throw error
            }
            self.channel = channel
            // The host key is known once key exchange has happened, which is
            // guaranteed by the time authentication succeeds.
            self.presentedHostKey = validator.observedFingerprint
        } catch let error as SSHError {
            self.presentedHostKey = validator.observedFingerprint
            throw error
        } catch {
            if validator.observedFingerprint != nil {
                self.presentedHostKey = validator.observedFingerprint
            }
            throw SSHError.connectFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        for forwarder in forwarders {
            await forwarder.stop()
        }
        forwarders.removeAll()
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
    }

    // MARK: - Running commands

    /// Runs a command and returns its output, whatever the exit status.
    public func run(_ command: String) async throws -> SSHCommandResult {
        guard let channel, channel.isActive else {
            throw SSHError.notConnected
        }

        let resultPromise = channel.eventLoop.makePromise(of: SSHCommandResult.self)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)

        // If the connection dies before the command finishes, nothing else
        // would ever fulfil these promises and NIO traps on a leaked promise.
        channel.closeFuture.whenComplete { _ in
            childPromise.fail(SSHError.notConnected)
            resultPromise.fail(SSHError.notConnected)
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .success(let handler):
                handler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                    childChannel.pipeline.addHandler(
                        SSHExecHandler(command: command, promise: resultPromise)
                    )
                }
            case .failure(let error):
                childPromise.fail(error)
                resultPromise.fail(SSHError.execFailed(String(describing: error)))
            }
        }

        do {
            _ = try await childPromise.futureResult.get()
        } catch {
            // Opening the channel failed, so the exec handler was never
            // installed and will never fulfil the result.
            resultPromise.fail(error)
            throw SSHError.execFailed(String(describing: error))
        }
        return try await resultPromise.futureResult.get()
    }

    /// Runs a command and fails unless it exits zero.
    @discardableResult
    public func runChecked(_ command: String) async throws -> SSHCommandResult {
        let result = try await run(command)
        guard result.status == 0 else {
            throw SSHError.commandFailed(command: command,
                                         status: result.status,
                                         stderr: result.error)
        }
        return result
    }

    // MARK: - Port forwarding

    /// Opens a local listener that forwards to `remoteHost:remotePort` on the
    /// far side of this SSH connection.
    ///
    /// Used to reach a VM's SPICE port without exposing it on the network.
    /// - Returns: the local port that was bound.
    public func forwardLocalPort(to remoteHost: String,
                                 remotePort: Int,
                                 localPort: Int = 0) async throws -> Int {
        guard let channel, channel.isActive else {
            throw SSHError.notConnected
        }
        let forwarder = SSHPortForwarder(sshChannel: channel,
                                         group: group,
                                         remoteHost: remoteHost,
                                         remotePort: remotePort)
        let boundPort = try await forwarder.start(localPort: localPort)
        forwarders.append(forwarder)
        return boundPort
    }

    /// Tears down a forward previously opened on this connection.
    public func closeForward(localPort: Int) async {
        guard let index = forwarders.firstIndex(where: { $0.localPort == localPort }) else {
            return
        }
        let forwarder = forwarders.remove(at: index)
        await forwarder.stop()
    }
}
