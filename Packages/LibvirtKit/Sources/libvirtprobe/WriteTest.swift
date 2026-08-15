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

/// Exercises the operations that change state on the host.
///
/// Opt-in and scoped: it refuses to run against anything but the domain and
/// pool named on the command line, and it removes everything it creates.
enum WriteTest {
    static func run(libvirt: LibvirtHost, domain: String, pool: String) async throws {
        print("\n── write tests on domain '\(domain)', pool '\(pool)' ──")

        let before = try await libvirt.state(ofDomain: domain)
        print("  domain state: \(before.rawValue)")
        guard !before.isActive else {
            throw TestFailure("refusing to run: '\(domain)' is active. Use a stopped VM.")
        }

        try await snapshotLifecycle(libvirt: libvirt, domain: domain)
        try await volumeLifecycle(libvirt: libvirt, pool: pool)
        try await autostartToggle(libvirt: libvirt, domain: domain)

        print("\n  all write tests passed, nothing left behind")
    }

    // MARK: - Snapshots

    private static func snapshotLifecycle(libvirt: LibvirtHost, domain: String) async throws {
        let name = "utmpro-verify-snapshot"
        let originals = try await libvirt.snapshots(ofDomain: domain)
        print("\n  snapshots before: \(originals.count)")

        print("  creating '\(name)' …")
        try await libvirt.createSnapshot(ofDomain: domain,
                                         named: name,
                                         description: "Created by UTM Pro verification, safe to delete")

        let created = try await libvirt.snapshots(ofDomain: domain)
        guard let snapshot = created.first(where: { $0.name == name }) else {
            throw TestFailure("snapshot was not listed after creation")
        }
        print("  created: \(snapshot.name)  state=\(snapshot.state ?? "?")  "
              + "memory=\(snapshot.includesMemory)  current=\(snapshot.isCurrent)")
        guard created.count == originals.count + 1 else {
            throw TestFailure("expected \(originals.count + 1) snapshots, got \(created.count)")
        }

        print("  reverting …")
        try await libvirt.revertSnapshot(ofDomain: domain, named: name)

        print("  deleting …")
        try await libvirt.deleteSnapshot(ofDomain: domain, named: name)

        let after = try await libvirt.snapshots(ofDomain: domain)
        guard !after.contains(where: { $0.name == name }) else {
            throw TestFailure("snapshot still present after deletion")
        }
        guard after.count == originals.count else {
            throw TestFailure("snapshot count did not return to \(originals.count)")
        }
        print("  snapshots after: \(after.count) ✓")
    }

    // MARK: - Volumes

    private static func volumeLifecycle(libvirt: LibvirtHost, pool: String) async throws {
        let name = "utmpro-verify.qcow2"
        let initialSize: UInt64 = 64 * 1024 * 1024
        let grownSize: UInt64 = 128 * 1024 * 1024

        let originals = try await libvirt.listVolumes(inPool: pool)
        print("\n  volumes before: \(originals.count)")
        guard !originals.contains(where: { $0.name == name }) else {
            throw TestFailure("'\(name)' already exists; refusing to touch it")
        }

        print("  creating '\(name)' at 64 MiB …")
        try await libvirt.createVolume(named: name,
                                       inPool: pool,
                                       capacityBytes: initialSize,
                                       format: .qcow2)

        let created = try await libvirt.listVolumes(inPool: pool)
        guard let volume = created.first(where: { $0.name == name }) else {
            throw TestFailure("volume was not listed after creation")
        }
        print("  created: \(volume.name)  format=\(volume.format ?? "?")  "
              + "capacity=\(volume.capacityBytes)  sparse=\(volume.isSparse)")
        guard volume.capacityBytes == initialSize else {
            throw TestFailure("expected capacity \(initialSize), got \(volume.capacityBytes)")
        }
        guard volume.format == "qcow2" else {
            throw TestFailure("expected qcow2, got \(volume.format ?? "nil")")
        }

        print("  resizing to 128 MiB …")
        try await libvirt.resizeVolume(named: name, inPool: pool, toBytes: grownSize)
        let resized = try await libvirt.listVolumes(inPool: pool)
        guard let grown = resized.first(where: { $0.name == name }) else {
            throw TestFailure("volume disappeared after resize")
        }
        guard grown.capacityBytes == grownSize else {
            throw TestFailure("expected capacity \(grownSize) after resize, got \(grown.capacityBytes)")
        }
        print("  resized: capacity=\(grown.capacityBytes) ✓")

        print("  reading back with qemu-img …")
        let info = try await libvirt.imageInfo(at: grown.path)
        guard info.format == "qcow2", info.virtualSize == grownSize else {
            throw TestFailure("qemu-img disagrees: format=\(info.format) size=\(info.virtualSize)")
        }
        print("  qemu-img: format=\(info.format) virtualSize=\(info.virtualSize) ✓")

        print("  deleting …")
        try await libvirt.deleteVolume(named: name, inPool: pool)
        let after = try await libvirt.listVolumes(inPool: pool)
        guard !after.contains(where: { $0.name == name }) else {
            throw TestFailure("volume still present after deletion")
        }
        print("  volumes after: \(after.count) ✓")
    }

    // MARK: - Autostart

    private static func autostartToggle(libvirt: LibvirtHost, domain: String) async throws {
        let original = try await libvirt.domain(named: domain).isAutostart
        print("\n  autostart is \(original)")

        try await libvirt.setAutostart(!original, forDomain: domain)
        let toggled = try await libvirt.domain(named: domain).isAutostart
        guard toggled == !original else {
            throw TestFailure("autostart did not change")
        }
        print("  toggled to \(toggled) ✓")

        try await libvirt.setAutostart(original, forDomain: domain)
        let restored = try await libvirt.domain(named: domain).isAutostart
        guard restored == original else {
            throw TestFailure("autostart was not restored to \(original)")
        }
        print("  restored to \(restored) ✓")
    }
}

struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
