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
import NIOSSH

/// A long-lived interactive command on the remote host.
///
/// Distinct from `run`, which collects output and returns once. A serial
/// console never finishes on its own: it streams until the user closes it, and
/// needs a terminal on the far side so the guest's getty behaves.
public final class SSHShellSession: @unchecked Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    /// Sends keystrokes to the remote command.
    public func send(_ data: Data) {
        guard channel.isActive else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        channel.writeAndFlush(wrapped, promise: nil)
    }

    /// Tells the remote side the terminal was resized, so full-screen programs
    /// on the guest redraw at the right size.
    public func resize(width: Int, height: Int) {
        guard channel.isActive else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: width,
            terminalRowHeight: height,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }

    public var isOpen: Bool {
        channel.isActive
    }
}

/// Streams an interactive command's output to a callback.
final class SSHShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let onOutput: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    private var didClose = false

    init(command: String,
         onOutput: @escaping @Sendable (Data) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.command = command
        self.onOutput = onOutput
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { _ in context.close(promise: nil) }
    }

    func channelActive(context: ChannelHandlerContext) {
        // The PTY has to come before the command. Without one, `virsh console`
        // refuses to attach and the guest's getty has no terminal to talk to.
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty).whenComplete { [weak self] _ in
            guard let self else { return }
            let exec = SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: true)
            context.triggerUserOutboundEvent(exec, promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data else { return }
        // Both streams go to the terminal: virsh writes its own messages to
        // stderr, and hiding them would leave the user staring at a blank
        // window wondering what went wrong.
        onOutput(Data(bytes.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish()
        context.close(promise: nil)
    }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        onClose()
    }
}

public extension SSHConnection {
    /// Starts an interactive command with a terminal attached.
    func openShell(command: String,
                   onOutput: @escaping @Sendable (Data) -> Void,
                   onClose: @escaping @Sendable () -> Void) async throws -> SSHShellSession {
        guard let channel = sshChannel, channel.isActive else {
            throw SSHError.notConnected
        }

        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        channel.closeFuture.whenComplete { _ in
            childPromise.fail(SSHError.notConnected)
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .success(let handler):
                handler.createChannel(childPromise, channelType: .session) { child, _ in
                    child.pipeline.addHandler(
                        SSHShellHandler(command: command, onOutput: onOutput, onClose: onClose)
                    )
                }
            case .failure(let error):
                childPromise.fail(error)
            }
        }

        do {
            let child = try await childPromise.futureResult.get()
            return SSHShellSession(channel: child)
        } catch {
            throw SSHError.execFailed(String(describing: error))
        }
    }
}
