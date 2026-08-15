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

/// Everything needed to define a new domain.
public struct LibvirtDomainTemplate: Sendable {
    public var name: String
    public var uuid: UUID
    public var notes: String?
    public var architecture: String
    public var machine: String
    public var memoryBytes: UInt64
    public var vcpuCount: Int

    /// Host path of the boot disk.
    public var diskPath: String
    public var diskFormat: LibvirtVolumeFormat

    /// Host path of an installer image to attach, if any.
    public var isoPath: String?

    /// How the guest reaches the network.
    public var network: Network

    /// Where the SPICE console listens.
    ///
    /// Defaults to loopback. UTM Pro tunnels the console over SSH, so there is
    /// no reason to expose it on the network — which is what most libvirt
    /// front ends do by default, unauthenticated.
    public var consoleListenAddress: String

    public enum Network: Sendable, Equatable {
        /// Attach to a host bridge, e.g. `br0`. The guest gets an address from
        /// the same network as the host.
        case bridge(String)
        /// Attach to a libvirt-managed virtual network, e.g. `default`.
        case virtualNetwork(String)
        case none
    }

    public init(name: String,
                uuid: UUID = UUID(),
                notes: String? = nil,
                architecture: String = "x86_64",
                machine: String = "q35",
                memoryBytes: UInt64,
                vcpuCount: Int,
                diskPath: String,
                diskFormat: LibvirtVolumeFormat = .qcow2,
                isoPath: String? = nil,
                network: Network = .none,
                consoleListenAddress: String = "127.0.0.1") {
        self.name = name
        self.uuid = uuid
        self.notes = notes
        self.architecture = architecture
        self.machine = machine
        self.memoryBytes = memoryBytes
        self.vcpuCount = vcpuCount
        self.diskPath = diskPath
        self.diskFormat = diskFormat
        self.isoPath = isoPath
        self.network = network
        self.consoleListenAddress = consoleListenAddress
    }

    /// Builds the domain XML.
    ///
    /// Modelled on what the OpenMediaVault KVM plugin produces, so a VM made
    /// here looks native in that web interface rather than like something
    /// foreign: q35 machine, host-passthrough CPU, virtio disk, network and
    /// video, SPICE with an agent channel.
    public func domainXML() -> String {
        var xml = XMLBuilder()
        xml.open("domain", ["type": "kvm"])

        xml.element("name", text: name)
        xml.element("uuid", text: uuid.uuidString.lowercased())
        if let notes, !notes.isEmpty {
            xml.element("description", text: notes)
        }

        // libvirt takes KiB here.
        let kibibytes = String(max(UInt64(1), memoryBytes / 1024))
        xml.element("memory", text: kibibytes, ["unit": "KiB"])
        xml.element("currentMemory", text: kibibytes, ["unit": "KiB"])
        xml.element("vcpu", text: String(max(1, vcpuCount)), ["placement": "static"])

        xml.open("os")
        xml.element("type", text: "hvm", ["arch": architecture, "machine": machine])
        // Boot order is set per device below, except for the installer case
        // where the firmware needs to try the CD first.
        if isoPath != nil {
            xml.empty("boot", ["dev": "cdrom"])
        }
        xml.empty("boot", ["dev": "hd"])
        xml.close()

        xml.open("features")
        xml.empty("acpi")
        xml.empty("apic")
        xml.close()

        xml.empty("cpu", ["mode": "host-passthrough", "check": "none", "migratable": "on"])

        xml.open("clock", ["offset": "utc"])
        xml.empty("timer", ["name": "rtc", "tickpolicy": "catchup"])
        xml.empty("timer", ["name": "pit", "tickpolicy": "delay"])
        xml.empty("timer", ["name": "hpet", "present": "no"])
        xml.close()

        xml.element("on_poweroff", text: "destroy")
        xml.element("on_reboot", text: "restart")
        xml.element("on_crash", text: "destroy")

        xml.open("devices")
        xml.element("emulator", text: emulatorPath)

        xml.open("disk", ["type": "file", "device": "disk"])
        xml.empty("driver", ["name": "qemu",
                             "type": diskFormat.rawValue,
                             "cache": "none",
                             "io": "native",
                             "discard": "unmap"])
        xml.empty("source", ["file": diskPath])
        xml.empty("target", ["dev": "vda", "bus": "virtio"])
        xml.close()

        if let isoPath {
            xml.open("disk", ["type": "file", "device": "cdrom"])
            xml.empty("driver", ["name": "qemu", "type": "raw"])
            xml.empty("source", ["file": isoPath])
            xml.empty("target", ["dev": "sda", "bus": "sata"])
            xml.empty("readonly")
            xml.close()
        }

        xml.empty("controller", ["type": "usb", "index": "0", "model": "qemu-xhci", "ports": "15"])
        xml.empty("controller", ["type": "virtio-serial", "index": "0"])

        switch network {
        case .bridge(let name):
            xml.open("interface", ["type": "bridge"])
            xml.empty("mac", ["address": Self.randomMACAddress()])
            xml.empty("source", ["bridge": name])
            xml.empty("model", ["type": "virtio"])
            xml.close()
        case .virtualNetwork(let name):
            xml.open("interface", ["type": "network"])
            xml.empty("mac", ["address": Self.randomMACAddress()])
            xml.empty("source", ["network": name])
            xml.empty("model", ["type": "virtio"])
            xml.close()
        case .none:
            break
        }

        xml.open("console", ["type": "pty"])
        xml.empty("target", ["type": "serial", "port": "0"])
        xml.close()

        // The SPICE agent channel is what makes clipboard sharing and
        // resolution changes work once the guest tools are installed.
        xml.open("channel", ["type": "spicevmc"])
        xml.empty("target", ["type": "virtio", "name": "com.redhat.spice.0"])
        xml.close()

        xml.empty("input", ["type": "tablet", "bus": "usb"])
        xml.empty("input", ["type": "keyboard", "bus": "ps2"])

        xml.open("graphics", ["type": "spice",
                              "port": "-1",
                              "autoport": "yes",
                              "listen": consoleListenAddress])
        xml.empty("listen", ["type": "address", "address": consoleListenAddress])
        xml.empty("image", ["compression": "off"])
        xml.close()

        xml.open("video")
        xml.empty("model", ["type": "virtio", "heads": "1", "primary": "yes"])
        xml.close()

        xml.empty("memballoon", ["model": "virtio"])

        xml.open("rng", ["model": "virtio"])
        xml.element("backend", text: "/dev/urandom", ["model": "random"])
        xml.close()

        xml.close() // devices
        xml.close() // domain
        return xml.document
    }

    private var emulatorPath: String {
        "/usr/bin/qemu-system-\(architecture)"
    }

    /// A locally-administered MAC in QEMU's assigned range.
    ///
    /// Random rather than sequential: two VMs created from different clients
    /// would otherwise collide, and a duplicate MAC on a bridge produces
    /// network faults that are miserable to diagnose.
    static func randomMACAddress() -> String {
        let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        return "52:54:00:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
