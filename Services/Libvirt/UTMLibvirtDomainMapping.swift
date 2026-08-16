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

/// The libvirt facts that have no place in a `UTMQemuConfiguration`.
///
/// A remote domain is projected into a QEMU configuration so it can use UTM's
/// existing display and settings views, but that model describes a VM this app
/// would launch itself. Everything that only makes sense for a domain running
/// on another host lives here instead of being forced into it.
struct UTMLibvirtDomainInfo {
    /// The name libvirt addresses the domain by. Unique per host, and what
    /// every virsh call uses. Distinct from the display name.
    var domainName: String

    var state: LibvirtDomainState

    var isAutostart: Bool

    /// Machine type as libvirt reports it, e.g. `pc-q35-10.0`. More precise
    /// than the QEMU target the projection can infer.
    var machine: String?

    var architecture: String?

    var graphics: [LibvirtGraphics]

    var interfaces: [LibvirtInterface]

    /// Host paths of the domain's disks, indexed by guest device name.
    var diskPaths: [String: String]

    /// Bridge or network name per interface, in order, so a save can tell
    /// which attachment actually changed.
    var interfaceSources: [String?] { interfaces.map(\.source) }

    /// Guest device names already in use, so a new disk gets a free one.
    var diskTargets: [String]

    /// Memory in MiB, matching how the projected configuration stores it, so
    /// a save can tell an actual edit from a rounding difference.
    var memorySizeMib: Int

    var vcpuCount: Int

    var notes: String?

    /// The server this domain belongs to.
    var serverId: UUID

    init(domain: LibvirtDomain, serverId: UUID) {
        self.domainName = domain.name
        self.state = domain.state
        self.isAutostart = domain.isAutostart
        self.machine = domain.machine
        self.architecture = domain.architecture
        self.graphics = domain.graphics
        self.interfaces = domain.interfaces
        self.serverId = serverId
        self.diskTargets = domain.disks.map(\.target).filter { !$0.isEmpty }
        self.memorySizeMib = Int(domain.memoryBytes / (1024 * 1024))
        self.vcpuCount = domain.vcpuCount
        self.notes = domain.notes
        self.diskPaths = domain.disks.reduce(into: [:]) { result, disk in
            if let path = disk.sourcePath {
                result[disk.target] = path
            }
        }
    }

    /// The console we would connect to, if any.
    var preferredGraphics: LibvirtGraphics? {
        graphics.first { $0.kind == .spice } ?? graphics.first
    }

    /// Whether the domain has a console UTM can render.
    ///
    /// Only SPICE: UTM's display stack is a SPICE client, and a VNC-only
    /// domain would need a different one entirely.
    var hasSupportedConsole: Bool {
        graphics.contains { $0.kind == .spice }
    }
}

// MARK: - Projection

@MainActor
extension UTMQemuConfiguration {
    /// Builds a configuration describing a remote libvirt domain.
    ///
    /// This is a read model. It carries enough for UTM's views to render the
    /// VM — name, hardware summary, a display, its disks — and deliberately
    /// does not attempt to reproduce the domain's full XML. Editing it does
    /// not change the domain; that goes through libvirt.
    static func projecting(domain: LibvirtDomain) -> UTMQemuConfiguration {
        let config = UTMQemuConfiguration()

        var information = UTMConfigurationInfo()
        information.name = domain.name
        information.uuid = domain.uuid
        information.notes = domain.notes
        config.information = information

        var system = UTMQemuConfigurationSystem()
        if let architecture = domain.architecture,
           let mapped = QEMUArchitecture(rawValue: architecture) {
            system.architecture = mapped
        }
        system.cpuCount = domain.vcpuCount
        // libvirt reports bytes; this model stores MiB.
        system.memorySize = Int(domain.memoryBytes / (1024 * 1024))
        config.system = system

        // A display entry is what makes UTM offer a graphical console at all.
        // Without a SPICE device there is nothing for the display stack to
        // attach to, so the VM is presented as headless instead.
        config.displays = domain.graphics.contains { $0.kind == .spice }
            ? [UTMQemuConfigurationDisplay()]
            : []

        config.drives = domain.disks.map { disk in
            var drive = UTMQemuConfigurationDrive()
            drive.imageName = disk.sourcePath.map { ($0 as NSString).lastPathComponent }
            drive.isExternal = disk.isCDROM
            drive.isReadOnly = disk.isReadOnly
            drive.imageType = disk.isCDROM ? .cd : .disk
            return drive
        }

        // Populated rather than left blank: an empty entry showed the VM as
        // having a network but told the user nothing about which one, and gave
        // an edit nothing to change.
        config.networks = domain.interfaces.map { interface in
            var network = UTMQemuConfigurationNetwork()
            network.mode = .bridged
            network.bridgeInterface = interface.source
            if let mac = interface.macAddress {
                network.macAddress = mac
            }
            return network
        }

        return config
    }

    /// Refreshes an existing projection in place, so views observing the
    /// configuration update rather than being rebuilt.
    func update(projecting domain: LibvirtDomain) {
        var information = self.information
        information.name = domain.name
        information.uuid = domain.uuid
        information.notes = domain.notes
        self.information = information

        var system = self.system
        if let architecture = domain.architecture,
           let mapped = QEMUArchitecture(rawValue: architecture) {
            system.architecture = mapped
        }
        system.cpuCount = domain.vcpuCount
        system.memorySize = Int(domain.memoryBytes / (1024 * 1024))
        self.system = system

        self.networks = domain.interfaces.map { interface in
            var network = UTMQemuConfigurationNetwork()
            network.mode = .bridged
            network.bridgeInterface = interface.source
            if let mac = interface.macAddress {
                network.macAddress = mac
            }
            return network
        }
    }
}
