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

/// A local listening socket whose connections are tunnelled to a remote
/// address over an established SSH connection — the equivalent of
/// `ssh -L localPort:remoteHost:remotePort`.
///
/// The listener binds to loopback only. A tunnel that accepted connections
/// from the network would re-expose exactly what tunnelling is meant to avoid.
final class SSHPortForwarder: @unchecked Sendable {
    private let sshChannel: Channel
    private let group: EventLoopGroup
    private let remoteHost: String
    private let remotePort: Int
    private var listener: Channel?

    private(set) var localPort: Int = 0

    init(sshChannel: Channel, group: EventLoopGroup, remoteHost: String, remotePort: Int) {
        self.sshChannel = sshChannel
        self.group = group
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func start(localPort requestedPort: Int) async throws -> Int {
        let sshChannel = self.sshChannel
        let remoteHost = self.remoteHost
        let remotePort = self.remotePort

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                Self.bridge(inbound: inbound,
                            sshChannel: sshChannel,
                            remoteHost: remoteHost,
                            remotePort: remotePort)
            }

        do {
            let listener = try await bootstrap.bind(host: "127.0.0.1", port: requestedPort).get()
            self.listener = listener
            self.localPort = listener.localAddress?.port ?? requestedPort
            return self.localPort
        } catch {
            throw SSHError.portForwardFailed(String(describing: error))
        }
    }

    func stop() async {
        if let listener {
            try? await listener.close().get()
        }
        listener = nil
    }

    /// Opens a `direct-tcpip` channel for one accepted local connection and
    /// splices the two channels together.
    private static func bridge(inbound: Channel,
                               sshChannel: Channel,
                               remoteHost: String,
                               remotePort: Int) -> EventLoopFuture<Void> {
        let childPromise = inbound.eventLoop.makePromise(of: Channel.self)

        let originator = inbound.remoteAddress
            ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
        guard let originator else {
            return inbound.eventLoop.makeFailedFuture(
                SSHError.portForwardFailed("no originating address")
            )
        }
        let target = SSHChannelType.DirectTCPIP(
            targetHost: remoteHost,
            targetPort: remotePort,
            originatorAddress: originator
        )

        sshChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .success(let handler):
                handler.createChannel(childPromise, channelType: .directTCPIP(target)) { child, _ in
                    child.pipeline.addHandler(SSHToLocalGlue(local: inbound))
                }
            case .failure(let error):
                childPromise.fail(error)
            }
        }

        return childPromise.futureResult.flatMap { child in
            inbound.pipeline.addHandler(LocalToSSHGlue(ssh: child))
        }.flatMapError { error in
            inbound.close(promise: nil)
            return inbound.eventLoop.makeFailedFuture(error)
        }
    }
}

/// Pumps bytes arriving on the SSH channel out to the local socket.
///
/// Only the `.channel` stream is forwarded: a `direct-tcpip` channel should
/// never carry stderr, and passing it through would corrupt the byte stream.
private final class SSHToLocalGlue: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer

    private let local: Channel

    init(local: Channel) {
        self.local = local
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(let bytes) = channelData.data else {
            return
        }
        local.writeAndFlush(bytes).whenFailure { _ in
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        local.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        local.close(promise: nil)
        context.close(promise: nil)
    }
}

/// Pumps bytes arriving on the local socket into the SSH channel.
private final class LocalToSSHGlue: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Never

    private let ssh: Channel

    init(ssh: Channel) {
        self.ssh = ssh
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(bytes))
        ssh.writeAndFlush(wrapped).whenFailure { _ in
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        ssh.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ssh.close(promise: nil)
        context.close(promise: nil)
    }
}
