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

/// Defines a domain from the template, checks libvirt kept what we asked for,
/// then removes it along with its disk.
///
/// The XML is written by hand, so "libvirt accepted it" is the only meaningful
/// test. It is never started: defining proves the document parses and
/// validates, which is what could be wrong.
enum CreateTest {
    static func run(libvirt: LibvirtHost, pool: String) async throws {
        let name = "utmpro-verify-vm"
        let volumeName = "\(name).qcow2"
        print("\n── create test in pool '\(pool)' ──")

        let existing = try await libvirt.listDomains()
        guard !existing.contains(where: { $0.name == name }) else {
            throw TestFailure("'\(name)' already exists; refusing to touch it")
        }

        try await libvirt.createVolume(named: volumeName,
                                       inPool: pool,
                                       capacityBytes: 1024 * 1024 * 1024,
                                       format: .qcow2)
        let volumes = try await libvirt.listVolumes(inPool: pool)
        guard let volume = volumes.first(where: { $0.name == volumeName }) else {
            throw TestFailure("boot volume was not created")
        }

        let networks = try await libvirt.listNetworkOptions()
        print("  networks offered: "
              + (networks.isEmpty ? "none" : networks.map(\.name).joined(separator: ", ")))
        let network: LibvirtDomainTemplate.Network = networks.first { $0.kind == .bridge }
            .map { .bridge($0.name) } ?? .none

        let template = LibvirtDomainTemplate(name: name,
                                             notes: "Created by UTM Pro verification",
                                             memoryBytes: 1024 * 1024 * 1024,
                                             vcpuCount: 2,
                                             diskPath: volume.path,
                                             network: network)

        print("  defining …")
        do {
            try await libvirt.define(domainXML: template.domainXML())
        } catch {
            try? await libvirt.deleteVolume(named: volumeName, inPool: pool)
            throw error
        }

        do {
            let created = try await libvirt.domain(named: name)
            guard created.vcpuCount == 2 else {
                throw TestFailure("expected 2 vcpu, got \(created.vcpuCount)")
            }
            guard created.memoryBytes == 1024 * 1024 * 1024 else {
                throw TestFailure("expected 1 GiB, got \(created.memoryBytes) bytes")
            }
            guard created.disks.contains(where: { $0.target == "vda" && $0.format == "qcow2" }) else {
                throw TestFailure("boot disk missing from the defined domain")
            }
            guard let graphics = created.preferredGraphics, graphics.kind == .spice else {
                throw TestFailure("no SPICE console in the defined domain")
            }
            // The whole point of setting this: the console must not be exposed
            // on the network, since UTM reaches it through the SSH tunnel.
            guard graphics.listenAddress == "127.0.0.1" else {
                throw TestFailure("console listens on \(graphics.listenAddress ?? "?"), expected 127.0.0.1")
            }
            guard created.notes == "Created by UTM Pro verification" else {
                throw TestFailure("description was not kept")
            }
            if case .bridge(let bridge) = network {
                guard created.interfaces.contains(where: { $0.source == bridge }) else {
                    throw TestFailure("interface not attached to \(bridge)")
                }
            }
            // USB redirection needs channels declared in the domain, and a
            // guest defined without them can never accept a device.
            let xml = try await libvirt.domainXML(named: name)
            let redirCount = xml.components(separatedBy: "<redirdev").count - 1
            guard redirCount >= 2 else {
                throw TestFailure("expected 2 USB redirection channels, found \(redirCount)")
            }
            print("  USB redirection channels: \(redirCount) ✓")

            // Moving an interface between bridges must keep the MAC, or the
            // guest loses its DHCP lease.
            if case .bridge = network, let mac = created.interfaces.first?.macAddress {
                try await libvirt.detachInterface(fromDomain: name, macAddress: mac)
                try await libvirt.attachInterface(toDomain: name, source: "docker0", macAddress: mac)
                let moved = try await libvirt.domain(named: name)
                guard moved.interfaces.first?.source == "docker0" else {
                    throw TestFailure("interface did not move, source is \(moved.interfaces.first?.source ?? "nil")")
                }
                guard moved.interfaces.first?.macAddress == mac else {
                    throw TestFailure("MAC changed when moving the interface")
                }
                print("  interface moved to docker0 keeping MAC \(mac) ✓")
            }

            print("  defined: \(created.vcpuCount) vcpu, "
                  + "\(created.memoryBytes / (1024 * 1024)) MiB, "
                  + "disk \(created.disks.map(\.target).joined(separator: ",")), "
                  + "spice on \(graphics.listenAddress ?? "?"), "
                  + "net \(created.interfaces.compactMap(\.source).joined(separator: ",")) ✓")
        } catch {
            try? await libvirt.undefine(domain: name)
            try? await libvirt.deleteVolume(named: volumeName, inPool: pool)
            throw error
        }

        // Delete with its storage, which is the path the app's delete dialog
        // takes when "also delete its disks" is ticked. Checking the volume is
        // gone matters: --remove-all-storage silently ignores disks it cannot
        // account for, which would leave the image orphaned.
        print("  deleting with storage …")
        try await libvirt.undefine(domain: name, removeStorage: true)

        let after = try await libvirt.listDomains()
        guard !after.contains(where: { $0.name == name }) else {
            throw TestFailure("domain still defined after undefine")
        }
        let remaining = try await libvirt.listVolumes(inPool: pool)
        if remaining.contains(where: { $0.name == volumeName }) {
            // Not fatal for the test, but the app must not claim it removed
            // the disks when it did not.
            print("  note: volume survived --remove-all-storage; cleaning up")
            try await libvirt.deleteVolume(named: volumeName, inPool: pool)
        } else {
            print("  volume removed with the domain ✓")
        }
        print("  removed ✓\n\n  create and delete work")
    }
}
