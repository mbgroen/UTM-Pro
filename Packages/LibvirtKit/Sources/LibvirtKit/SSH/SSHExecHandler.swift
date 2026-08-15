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

/// The result of running one command on the remote host.
public struct SSHCommandResult: Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    /// Standard output decoded as UTF-8, with trailing newlines removed.
    public var output: String {
        String(decoding: standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Standard error decoded as UTF-8, with trailing newlines removed.
    public var error: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a single command on an SSH session channel and collects its output.
///
/// One handler serves one command: the channel is closed when the command
/// finishes, which is how the SSH session protocol works.
final class SSHExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let promise: EventLoopPromise<SSHCommandResult>
    private var standardOutput = ByteBufferAllocator().buffer(capacity: 0)
    private var standardError = ByteBufferAllocator().buffer(capacity: 0)
    private var exitStatus: Int32?
    private var completed = false

    init(command: String, promise: EventLoopPromise<SSHCommandResult>) {
        self.command = command
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [weak self] error in
                self?.fail(error)
            }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).whenFailure { [weak self] error in
            self?.fail(SSHError.execFailed(String(describing: error)))
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        switch channelData.type {
        case .channel:
            standardOutput.writeBuffer(&bytes)
        case .stdErr:
            standardError.writeBuffer(&bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        let result = SSHCommandResult(
            status: exitStatus ?? -1,
            standardOutput: Data(standardOutput.readableBytesView),
            standardError: Data(standardError.readableBytesView)
        )
        promise.succeed(result)
    }

    private func fail(_ error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }
}
