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

/// A drive belonging to a remote libvirt domain.
///
/// Unlike a local drive this is a view of something that lives on the remote
/// host: `imageName` is the file name on the NAS, not a file inside a `.utm`
/// bundle, and nothing here is ever written to local storage.
struct UTMLibvirtConfigurationDrive: UTMConfigurationDrive {
    var imageName: String?

    /// Host path of the backing image.
    var remotePath: String?

    /// Guest device name, e.g. `vda`.
    var target: String = ""

    var bus: String?

    /// Image format as libvirt reports it.
    var imageFormat: String?

    var isCDROM: Bool = false

    var isReadOnly: Bool = false

    /// Virtual size in bytes, as the guest sees it.
    var capacityBytes: UInt64 = 0

    /// Space actually consumed on the host.
    var allocationBytes: UInt64 = 0

    /// Stable within a domain: libvirt guarantees one device name per disk.
    private(set) var id: String

    /// Always nil. The protocol means "where the image is on this device", and
    /// a remote image has no local location — pointing this at the host's path
    /// would invite local file operations on a path that does not exist here.
    var imageURL: URL? {
        get { nil }
        set { }
    }

    var sizeMib: Int {
        Int(capacityBytes / (1024 * 1024))
    }

    func clone() -> UTMLibvirtConfigurationDrive {
        var copy = self
        copy.id = UUID().uuidString
        return copy
    }

    var isExternal: Bool {
        // Every remote drive is external in the sense the protocol means:
        // it is not stored inside a local package.
        true
    }

    var isRawImage: Bool {
        imageFormat == "raw"
    }

    /// Whether this drive can take part in an internal snapshot.
    var supportsInternalSnapshots: Bool {
        imageFormat == "qcow2" && !isReadOnly && !isCDROM
    }

    init(from disk: LibvirtDisk) {
        self.id = disk.target.isEmpty ? (disk.sourcePath ?? UUID().uuidString) : disk.target
        self.remotePath = disk.sourcePath
        self.imageName = disk.sourcePath.map { ($0 as NSString).lastPathComponent }
        self.target = disk.target
        self.bus = disk.bus
        self.imageFormat = disk.format
        self.isCDROM = disk.isCDROM
        self.isReadOnly = disk.isReadOnly
    }
}

/// Configuration for a virtual machine that lives on a remote libvirt host.
///
/// This is a projection of the domain's XML rather than a file format of its
/// own: the host is the source of truth, and this is refreshed from it. It
/// conforms to `UTMConfiguration` so remote VMs can flow through the same
/// views, list model and session machinery as local ones.
@MainActor
final class UTMLibvirtConfiguration: UTMConfiguration {
    @Published private(set) var _information = UTMConfigurationInfo()

    var information: UTMConfigurationInfo {
        get { _information }
        set { _information = newValue }
    }

    @Published var drives: [UTMLibvirtConfigurationDrive] = []

    var backend: UTMBackend { .libvirt }

    // MARK: - Remote facts

    /// The domain name on the host, which is how libvirt addresses it. This is
    /// distinct from `information.name`: libvirt names are unique per host and
    /// are what every `virsh` call uses.
    @Published private(set) var domainName: String = ""

    @Published private(set) var state: LibvirtDomainState = .unknown

    /// Maximum memory in bytes.
    @Published private(set) var memoryBytes: UInt64 = 0

    @Published private(set) var vcpuCount: Int = 1

    @Published private(set) var architecture: String?

    @Published private(set) var machine: String?

    @Published private(set) var isAutostart: Bool = false

    @Published private(set) var graphics: [LibvirtGraphics] = []

    @Published private(set) var interfaces: [LibvirtInterface] = []

    /// Identifier of the server this domain lives on.
    private(set) var serverId: UUID

    // MARK: - Init

    init(domain: LibvirtDomain, serverId: UUID) {
        self.serverId = serverId
        self.apply(domain: domain)
    }

    /// Refreshes every field from a newly read domain.
    func apply(domain: LibvirtDomain) {
        var information = UTMConfigurationInfo()
        information.name = domain.name
        information.uuid = domain.uuid
        information.notes = domain.notes
        self._information = information

        self.domainName = domain.name
        self.state = domain.state
        self.memoryBytes = domain.memoryBytes
        self.vcpuCount = domain.vcpuCount
        self.architecture = domain.architecture
        self.machine = domain.machine
        self.isAutostart = domain.isAutostart
        self.graphics = domain.graphics
        self.interfaces = domain.interfaces
        self.drives = domain.disks.map(UTMLibvirtConfigurationDrive.init(from:))
    }

    /// The console we would connect to, if any.
    var preferredGraphics: LibvirtGraphics? {
        graphics.first { $0.kind == .spice } ?? graphics.first
    }

    /// True when at least one drive can hold an internal snapshot.
    var supportsInternalSnapshots: Bool {
        drives.contains { $0.supportsInternalSnapshots }
    }

    // MARK: - UTMConfiguration

    /// Remote configurations are never written to a local package. The
    /// protocol requires these, and the honest implementation is to do
    /// nothing rather than to write a misleading file.
    func prepareSave(for packageURL: URL) async throws {
    }

    func saveData(to dataURL: URL) async throws -> [URL] {
        []
    }

    // MARK: - Codable

    /// Encoding exists only to satisfy the protocol. A remote domain is
    /// reconstructed from the host, never from an archived copy, so decoding
    /// is refused rather than silently producing a stale VM.
    enum CodingKeys: String, CodingKey {
        case information
        case domainName
        case serverId
    }

    nonisolated init(from decoder: Decoder) throws {
        throw UTMConfigurationError.invalidBackend
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try MainActor.assumeIsolated {
            try container.encode(_information, forKey: .information)
            try container.encode(domainName, forKey: .domainName)
            try container.encode(serverId, forKey: .serverId)
        }
    }
}
