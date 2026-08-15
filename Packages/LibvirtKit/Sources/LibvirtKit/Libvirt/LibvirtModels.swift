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

// MARK: - Domains

/// The runtime state of a domain, as reported by libvirt.
public enum LibvirtDomainState: String, Sendable, CaseIterable {
    case running
    case idle
    case paused
    case inShutdown = "in shutdown"
    case shutOff = "shut off"
    case crashed
    case suspended = "pmsuspended"
    case unknown

    init(virshState: String) {
        let normalised = virshState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = LibvirtDomainState(rawValue: normalised) ?? .unknown
    }

    public var isActive: Bool {
        switch self {
        case .running, .idle, .paused, .inShutdown, .suspended:
            return true
        case .shutOff, .crashed, .unknown:
            return false
        }
    }
}

/// A disk attached to a domain.
public struct LibvirtDisk: Sendable, Hashable {
    /// The guest-side device name, e.g. `vda`.
    public let target: String
    /// The guest-side bus, e.g. `virtio`, `sata`.
    public let bus: String?
    /// Host path of the backing file, when the disk is file-backed.
    public let sourcePath: String?
    /// Image format, e.g. `qcow2`, `raw`.
    public let format: String?
    /// `disk` or `cdrom`.
    public let device: String
    public let isReadOnly: Bool

    public var isCDROM: Bool { device == "cdrom" }

    /// Whether this disk can hold an internal snapshot.
    ///
    /// Internal snapshots are a qcow2 feature. Raw disks and read-only media
    /// silently refuse them, so we surface that before the user tries.
    public var supportsInternalSnapshots: Bool {
        format == "qcow2" && !isReadOnly && !isCDROM
    }
}

/// A graphics device exposed by a domain.
public struct LibvirtGraphics: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case spice
        case vnc
    }

    public let kind: Kind
    public let port: Int?
    public let listenAddress: String?
    public let hasPassword: Bool

    /// True when the device listens on every interface.
    ///
    /// Combined with `hasPassword == false` this means anyone who can reach
    /// the host can open the console.
    public var isListeningOnAllInterfaces: Bool {
        listenAddress == "0.0.0.0" || listenAddress == "::"
    }
}

/// A network interface attached to a domain.
public struct LibvirtInterface: Sendable, Hashable {
    public let macAddress: String?
    /// `bridge`, `network`, `direct`, …
    public let kind: String
    /// The bridge name or libvirt network name.
    public let source: String?
    public let model: String?
}

/// A domain (virtual machine) on a libvirt host.
public struct LibvirtDomain: Sendable, Identifiable, Hashable {
    public let uuid: UUID
    public let name: String
    public let state: LibvirtDomainState
    /// Maximum memory in bytes.
    public let memoryBytes: UInt64
    /// Currently allocated memory in bytes.
    public let currentMemoryBytes: UInt64
    public let vcpuCount: Int
    public let architecture: String?
    public let machine: String?
    public let title: String?
    public let notes: String?
    public let disks: [LibvirtDisk]
    public let graphics: [LibvirtGraphics]
    public let interfaces: [LibvirtInterface]
    public let isAutostart: Bool

    public var id: UUID { uuid }

    /// The preferred console device, favouring SPICE for its richer feature
    /// set (clipboard, audio, USB redirection) over VNC.
    public var preferredGraphics: LibvirtGraphics? {
        graphics.first { $0.kind == .spice } ?? graphics.first
    }

    /// Whether any attached disk can hold an internal snapshot.
    public var supportsInternalSnapshots: Bool {
        disks.contains { $0.supportsInternalSnapshots }
    }
}

// MARK: - Snapshots

/// A domain snapshot.
public struct LibvirtSnapshot: Sendable, Identifiable, Hashable {
    public let name: String
    public let creationDate: Date?
    /// The domain state captured in the snapshot, e.g. `running`, `shutoff`.
    public let state: String?
    public let isCurrent: Bool
    public let parentName: String?
    public let notes: String?

    public var id: String { name }

    /// True when the snapshot captured live memory, so reverting resumes
    /// execution rather than booting.
    public var includesMemory: Bool {
        state == "running" || state == "paused"
    }
}

// MARK: - Storage

/// A libvirt storage pool.
public struct LibvirtPool: Sendable, Identifiable, Hashable {
    public let uuid: UUID?
    public let name: String
    public let isActive: Bool
    public let isAutostart: Bool
    public let capacityBytes: UInt64
    public let allocationBytes: UInt64
    public let availableBytes: UInt64
    /// `dir`, `logical`, `netfs`, `zfs`, …
    public let type: String?
    /// Host filesystem path for directory-backed pools.
    public let targetPath: String?

    public var id: String { name }

    public var usedFraction: Double {
        guard capacityBytes > 0 else { return 0 }
        return min(1, Double(allocationBytes) / Double(capacityBytes))
    }
}

/// A volume within a storage pool.
public struct LibvirtVolume: Sendable, Identifiable, Hashable {
    public let name: String
    public let poolName: String
    public let path: String
    /// Virtual size as the guest sees it.
    public let capacityBytes: UInt64
    /// Actual space consumed on the host, which is smaller for sparse images.
    public let allocationBytes: UInt64
    public let format: String?

    public var id: String { "\(poolName)/\(name)" }

    /// True when the image is thin-provisioned on disk.
    public var isSparse: Bool {
        allocationBytes < capacityBytes
    }
}

/// Formats a libvirt volume can be created in.
public enum LibvirtVolumeFormat: String, Sendable, CaseIterable, Identifiable {
    case qcow2
    case raw

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qcow2:
            return NSLocalizedString("QCOW2 (sparse, snapshots)", comment: "LibvirtVolumeFormat")
        case .raw:
            return NSLocalizedString("Raw (fastest, no snapshots)", comment: "LibvirtVolumeFormat")
        }
    }
}

// MARK: - Host

/// Static facts about a libvirt host.
public struct LibvirtHostInfo: Sendable, Hashable {
    public let hostname: String?
    public let hypervisorVersion: String?
    public let libvirtVersion: String?
    public let cpuModel: String?
    public let cpuCount: Int?
    public let memoryBytes: UInt64?
}
