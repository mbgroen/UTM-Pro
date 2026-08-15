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

/// Converts a libvirt memory element to bytes.
///
/// libvirt writes sizes with a `unit` attribute and defaults to KiB when the
/// attribute is absent — a default that is easy to miss and produces values
/// off by 1024.
func libvirtBytes(from node: XMLNode?) -> UInt64? {
    guard let node, let amount = node.uint64Value else { return nil }
    let unit = node.attribute("unit")?.lowercased() ?? "kib"
    let multiplier: UInt64
    switch unit {
    case "b", "bytes": multiplier = 1
    case "kb": multiplier = 1_000
    case "k", "kib": multiplier = 1 << 10
    case "mb": multiplier = 1_000_000
    case "m", "mib": multiplier = 1 << 20
    case "gb": multiplier = 1_000_000_000
    case "g", "gib": multiplier = 1 << 30
    case "tb": multiplier = 1_000_000_000_000
    case "t", "tib": multiplier = 1 << 40
    default: multiplier = 1 << 10
    }
    return amount.multipliedReportingOverflow(by: multiplier).overflow
        ? UInt64.max
        : amount * multiplier
}

// MARK: - Domain

extension LibvirtDomain {
    /// Builds a domain from `virsh dumpxml` output.
    ///
    /// - Parameters:
    ///   - xml: the domain XML.
    ///   - state: the state from `virsh domstate`, which the XML does not carry.
    ///   - isAutostart: from `virsh dominfo`, likewise absent from the XML.
    init(xml: String, state: LibvirtDomainState, isAutostart: Bool) throws {
        let root = try XMLNode.parse(xml)
        guard root.name == "domain" else {
            throw LibvirtError.missingElement("domain")
        }
        guard let name = root["name"]?.trimmedText, !name.isEmpty else {
            throw LibvirtError.missingElement("domain/name")
        }
        guard let uuidText = root["uuid"]?.trimmedText, let uuid = UUID(uuidString: uuidText) else {
            throw LibvirtError.missingElement("domain/uuid")
        }

        self.name = name
        self.uuid = uuid
        self.state = state
        self.isAutostart = isAutostart
        self.memoryBytes = libvirtBytes(from: root["memory"]) ?? 0
        self.currentMemoryBytes = libvirtBytes(from: root["currentMemory"]) ?? self.memoryBytes
        self.vcpuCount = root["vcpu"]?.intValue ?? 1

        let osType = root["os"]?["type"]
        self.architecture = osType?.attribute("arch")
        self.machine = osType?.attribute("machine")

        self.title = root["title"]?.trimmedText.nilIfEmpty
        self.notes = root["description"]?.trimmedText.nilIfEmpty

        let devices = root["devices"]
        self.disks = (devices?.all("disk") ?? []).map(LibvirtDisk.init(node:))
        self.graphics = (devices?.all("graphics") ?? []).compactMap(LibvirtGraphics.init(node:))
        self.interfaces = (devices?.all("interface") ?? []).map(LibvirtInterface.init(node:))
    }
}

extension LibvirtDisk {
    init(node: XMLNode) {
        let source = node["source"]
        self.sourcePath = source?.attribute("file")
            ?? source?.attribute("dev")
            ?? source?.attribute("name")
        self.format = node["driver"]?.attribute("type")
        self.target = node["target"]?.attribute("dev") ?? ""
        self.bus = node["target"]?.attribute("bus")
        self.device = node.attribute("device") ?? "disk"
        self.isReadOnly = node["readonly"] != nil
    }
}

extension LibvirtGraphics {
    init?(node: XMLNode) {
        guard let kindText = node.attribute("type"),
              let kind = Kind(rawValue: kindText) else {
            // Other graphics types (egl-headless, sdl) have no console we can
            // attach to, so they are not represented.
            return nil
        }
        self.kind = kind
        // autoport='yes' with the VM shut off yields port -1.
        let port = node.attribute("port").flatMap(Int.init)
        self.port = (port ?? -1) > 0 ? port : nil
        self.listenAddress = node.attribute("listen")
            ?? node["listen"]?.attribute("address")
        self.hasPassword = !(node.attribute("passwd")?.isEmpty ?? true)
    }
}

extension LibvirtInterface {
    init(node: XMLNode) {
        self.kind = node.attribute("type") ?? "network"
        self.macAddress = node["mac"]?.attribute("address")
        let source = node["source"]
        self.source = source?.attribute("bridge")
            ?? source?.attribute("network")
            ?? source?.attribute("dev")
        self.model = node["model"]?.attribute("type")
    }
}

// MARK: - Snapshot

extension LibvirtSnapshot {
    init(xml: String, isCurrent: Bool) throws {
        let root = try XMLNode.parse(xml)
        guard let name = root["name"]?.trimmedText, !name.isEmpty else {
            throw LibvirtError.missingElement("domainsnapshot/name")
        }
        self.name = name
        self.isCurrent = isCurrent
        self.state = root["state"]?.trimmedText.nilIfEmpty
        self.parentName = root["parent"]?["name"]?.trimmedText.nilIfEmpty
        self.notes = root["description"]?.trimmedText.nilIfEmpty
        if let epoch = root["creationTime"]?.trimmedText, let seconds = TimeInterval(epoch) {
            self.creationDate = Date(timeIntervalSince1970: seconds)
        } else {
            self.creationDate = nil
        }
    }
}

// MARK: - Pool

extension LibvirtPool {
    init(xml: String, isActive: Bool, isAutostart: Bool) throws {
        let root = try XMLNode.parse(xml)
        guard root.name == "pool" else {
            throw LibvirtError.missingElement("pool")
        }
        guard let name = root["name"]?.trimmedText, !name.isEmpty else {
            throw LibvirtError.missingElement("pool/name")
        }
        self.name = name
        self.isActive = isActive
        self.isAutostart = isAutostart
        self.uuid = UUID(uuidString: root["uuid"]?.trimmedText ?? "")
        self.type = root.attribute("type")
        self.capacityBytes = libvirtBytes(from: root["capacity"]) ?? 0
        self.allocationBytes = libvirtBytes(from: root["allocation"]) ?? 0
        self.availableBytes = libvirtBytes(from: root["available"]) ?? 0
        self.targetPath = root["target"]?["path"]?.trimmedText.nilIfEmpty
    }
}

// MARK: - Volume

extension LibvirtVolume {
    init(xml: String, poolName: String) throws {
        let root = try XMLNode.parse(xml)
        guard root.name == "volume" else {
            throw LibvirtError.missingElement("volume")
        }
        guard let name = root["name"]?.trimmedText, !name.isEmpty else {
            throw LibvirtError.missingElement("volume/name")
        }
        self.name = name
        self.poolName = poolName
        self.path = root["target"]?["path"]?.trimmedText ?? ""
        self.capacityBytes = libvirtBytes(from: root["capacity"]) ?? 0
        self.allocationBytes = libvirtBytes(from: root["allocation"]) ?? 0
        self.format = root["target"]?["format"]?.attribute("type")
    }
}

// MARK: - Host info

extension LibvirtHostInfo {
    /// Parses the key/value table `virsh nodeinfo` prints.
    init(nodeinfo: String, hostname: String?, libvirtVersion: String?, hypervisorVersion: String?) {
        var fields: [String: String] = [:]
        for line in nodeinfo.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        self.hostname = hostname?.nilIfEmpty
        self.libvirtVersion = libvirtVersion?.nilIfEmpty
        self.hypervisorVersion = hypervisorVersion?.nilIfEmpty
        self.cpuModel = fields["cpu model"]
        self.cpuCount = fields["cpu(s)"].flatMap(Int.init)
        // nodeinfo reports memory in KiB.
        self.memoryBytes = fields["memory size"]
            .flatMap { $0.split(separator: " ").first.map(String.init) }
            .flatMap(UInt64.init)
            .map { $0 * 1024 }
    }
}

// MARK: - Helpers

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
