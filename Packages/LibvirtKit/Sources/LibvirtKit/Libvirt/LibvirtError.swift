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

public enum LibvirtError: Error, Sendable, Equatable {
    /// libvirt returned XML we could not parse.
    case malformedXML(String)

    /// A required element was missing from otherwise valid XML.
    case missingElement(String)

    /// The named domain does not exist on this host.
    case noSuchDomain(String)

    /// The named storage pool does not exist on this host.
    case noSuchPool(String)

    /// The named volume does not exist in that pool.
    case noSuchVolume(pool: String, volume: String)

    /// `virsh` is not installed, or not on the remote user's PATH.
    case virshUnavailable

    /// The operation is not valid for the domain's current state.
    case invalidState(String)

    /// The remote host refused the operation.
    case refused(String)
}

extension LibvirtError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML(let detail):
            return String(format: NSLocalizedString("The host returned XML that could not be read: %@", comment: "LibvirtError"), detail)
        case .missingElement(let element):
            return String(format: NSLocalizedString("The host's response was missing the '%@' element.", comment: "LibvirtError"), element)
        case .noSuchDomain(let name):
            return String(format: NSLocalizedString("There is no virtual machine named '%@' on this host.", comment: "LibvirtError"), name)
        case .noSuchPool(let name):
            return String(format: NSLocalizedString("There is no storage pool named '%@' on this host.", comment: "LibvirtError"), name)
        case .noSuchVolume(let pool, let volume):
            return String(format: NSLocalizedString("There is no volume named '%@' in the pool '%@'.", comment: "LibvirtError"), volume, pool)
        case .virshUnavailable:
            return NSLocalizedString("The host does not have virsh installed, or it is not on the login user's PATH.", comment: "LibvirtError")
        case .invalidState(let detail):
            return String(format: NSLocalizedString("The virtual machine is not in a state that allows this: %@", comment: "LibvirtError"), detail)
        case .refused(let detail):
            return String(format: NSLocalizedString("The host refused the operation: %@", comment: "LibvirtError"), detail)
        }
    }
}
