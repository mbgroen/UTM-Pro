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

import NIOCore
import NIOSSH

/// Completes a promise once user authentication succeeds.
///
/// `ClientBootstrap.connect` resolves when the TCP connection is established,
/// which is several round trips before SSH is usable. Without waiting for this
/// event, the first command races the handshake and fails with an opaque
/// channel error.
final class SSHAuthenticationWaiter: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private var promise: EventLoopPromise<Void>?

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The server closes the connection when it rejects every credential we
        // offer, so reaching here un-authenticated means the login failed.
        promise?.fail(SSHError.authenticationFailed)
        promise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(error)
        promise = nil
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        promise?.fail(SSHError.notConnected)
        promise = nil
    }
}
