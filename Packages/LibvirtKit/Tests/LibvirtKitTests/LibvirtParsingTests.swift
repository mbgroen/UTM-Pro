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

import XCTest
@testable import LibvirtKit

/// Fixtures are real output from an OpenMediaVault 8 host running the
/// openmediavault-kvm plugin, so the parser is exercised against the shape
/// libvirt actually emits rather than a tidied-up sample.
final class LibvirtParsingTests: XCTestCase {

    // MARK: - Domain

    func testParsesRunningDomain() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)

        XCTAssertEqual(domain.name, "Pi-hole")
        XCTAssertEqual(domain.uuid, UUID(uuidString: "26b590fc-9534-42f6-b5ef-821121435bd7"))
        XCTAssertEqual(domain.state, .running)
        XCTAssertTrue(domain.isAutostart)
        XCTAssertEqual(domain.vcpuCount, 1)
        XCTAssertEqual(domain.architecture, "x86_64")
        XCTAssertEqual(domain.machine, "pc-q35-7.2")
        XCTAssertEqual(domain.notes, "Pi-hole DNS server")
    }

    /// The XML says `<memory unit='KiB'>2097152</memory>`, which is 2 GiB.
    /// Treating it as bytes would report 2 MiB.
    func testMemoryUnitIsHonoured() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)
        XCTAssertEqual(domain.memoryBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(domain.currentMemoryBytes, 2 * 1024 * 1024 * 1024)
    }

    func testMemoryDefaultsToKibibytesWhenUnitAbsent() throws {
        let xml = "<domain><memory>1024</memory></domain>"
        let node = try XMLNode.parse(xml)
        XCTAssertEqual(libvirtBytes(from: node["memory"]), 1024 * 1024)
    }

    func testParsesDisk() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)
        let disk = try XCTUnwrap(domain.disks.first)

        XCTAssertEqual(disk.target, "vda")
        XCTAssertEqual(disk.bus, "virtio")
        XCTAssertEqual(disk.format, "qcow2")
        XCTAssertEqual(disk.device, "disk")
        XCTAssertFalse(disk.isReadOnly)
        XCTAssertEqual(disk.sourcePath,
                       "/srv/dev-disk-by-uuid-56c27fbb-fa6a-4220-b42b-beb672d3cec1/KVM/Production/Pi-hole.qcow2")
        XCTAssertTrue(disk.supportsInternalSnapshots)
    }

    func testRawDiskDoesNotSupportInternalSnapshots() {
        let disk = LibvirtDisk(target: "vdb", bus: "virtio", sourcePath: "/tmp/x.img",
                               format: "raw", device: "disk", isReadOnly: false)
        XCTAssertFalse(disk.supportsInternalSnapshots)
    }

    func testCDROMDoesNotSupportInternalSnapshots() {
        let disk = LibvirtDisk(target: "sda", bus: "sata", sourcePath: "/iso/debian.iso",
                               format: "raw", device: "cdrom", isReadOnly: true)
        XCTAssertTrue(disk.isCDROM)
        XCTAssertFalse(disk.supportsInternalSnapshots)
    }

    func testParsesBothGraphicsDevicesAndPrefersSpice() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)
        XCTAssertEqual(domain.graphics.count, 2)

        let spice = try XCTUnwrap(domain.preferredGraphics)
        XCTAssertEqual(spice.kind, .spice)
        XCTAssertEqual(spice.port, 5901)
    }

    /// This host exposes consoles on every interface with no password. The
    /// model surfaces that so the UI can warn rather than silently connecting
    /// across the network in the clear.
    func testDetectsUnauthenticatedConsoleOnAllInterfaces() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)
        let spice = try XCTUnwrap(domain.preferredGraphics)

        XCTAssertEqual(spice.listenAddress, "0.0.0.0")
        XCTAssertTrue(spice.isListeningOnAllInterfaces)
        XCTAssertFalse(spice.hasPassword)
    }

    /// A stopped domain with `autoport='yes'` reports port -1, which is not a
    /// port we could ever connect to.
    func testNegativePortIsTreatedAsAbsent() throws {
        let xml = """
        <domain><devices>
        <graphics type='spice' port='-1' autoport='yes' listen='127.0.0.1'/>
        </devices></domain>
        """
        let node = try XMLNode.parse(xml)
        let graphics = try XCTUnwrap(LibvirtGraphics(node: XCTUnwrap(node.firstDescendant("graphics"))))
        XCTAssertNil(graphics.port)
    }

    func testParsesBridgedInterface() throws {
        let domain = try LibvirtDomain(xml: Fixtures.piHoleDomain, state: .running, isAutostart: true)
        let interface = try XCTUnwrap(domain.interfaces.first)

        XCTAssertEqual(interface.kind, "bridge")
        XCTAssertEqual(interface.source, "br0")
        XCTAssertEqual(interface.macAddress, "52:54:00:57:2f:0c")
        XCTAssertEqual(interface.model, "virtio")
    }

    func testMissingUUIDIsRejected() {
        let xml = "<domain><name>x</name></domain>"
        XCTAssertThrowsError(try LibvirtDomain(xml: xml, state: .running, isAutostart: false))
    }

    func testNonDomainRootIsRejected() {
        let xml = "<pool><name>x</name></pool>"
        XCTAssertThrowsError(try LibvirtDomain(xml: xml, state: .running, isAutostart: false))
    }

    // MARK: - State

    func testParsesMultiWordState() {
        XCTAssertEqual(LibvirtDomainState(virshState: "shut off"), .shutOff)
        XCTAssertEqual(LibvirtDomainState(virshState: "running\n"), .running)
        XCTAssertEqual(LibvirtDomainState(virshState: "  paused  "), .paused)
        XCTAssertEqual(LibvirtDomainState(virshState: "something else"), .unknown)
    }

    func testActiveStates() {
        XCTAssertTrue(LibvirtDomainState.running.isActive)
        XCTAssertTrue(LibvirtDomainState.paused.isActive)
        XCTAssertFalse(LibvirtDomainState.shutOff.isActive)
        XCTAssertFalse(LibvirtDomainState.crashed.isActive)
    }

    // MARK: - Snapshot

    func testParsesSnapshot() throws {
        let snapshot = try LibvirtSnapshot(xml: Fixtures.snapshot, isCurrent: true)

        XCTAssertEqual(snapshot.name, "1775070450")
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertTrue(snapshot.isCurrent)
        XCTAssertTrue(snapshot.includesMemory)
        XCTAssertEqual(snapshot.creationDate, Date(timeIntervalSince1970: 1775070450))
    }

    func testSnapshotOfStoppedDomainHasNoMemory() throws {
        let xml = """
        <domainsnapshot><name>cold</name><state>shutoff</state>
        <creationTime>1775070450</creationTime></domainsnapshot>
        """
        let snapshot = try LibvirtSnapshot(xml: xml, isCurrent: false)
        XCTAssertFalse(snapshot.includesMemory)
    }

    // MARK: - Pool

    func testParsesPool() throws {
        let pool = try LibvirtPool(xml: Fixtures.pool, isActive: true, isAutostart: true)

        XCTAssertEqual(pool.name, "Production")
        XCTAssertEqual(pool.type, "dir")
        XCTAssertTrue(pool.isActive)
        XCTAssertEqual(pool.capacityBytes, 11_904_911_519_744)
        XCTAssertEqual(pool.allocationBytes, 2_387_372_220_416)
        XCTAssertEqual(pool.targetPath,
                       "/srv/dev-disk-by-uuid-56c27fbb-fa6a-4220-b42b-beb672d3cec1/KVM/Production")
        XCTAssertEqual(pool.usedFraction, 0.2005, accuracy: 0.001)
    }

    func testPoolUsedFractionHandlesZeroCapacity() throws {
        let xml = "<pool type='dir'><name>empty</name><capacity unit='bytes'>0</capacity></pool>"
        let pool = try LibvirtPool(xml: xml, isActive: false, isAutostart: false)
        XCTAssertEqual(pool.usedFraction, 0)
    }

    // MARK: - Volume

    func testParsesVolume() throws {
        let volume = try LibvirtVolume(xml: Fixtures.volume, poolName: "Production")

        XCTAssertEqual(volume.name, "Pi-hole.qcow2")
        XCTAssertEqual(volume.format, "qcow2")
        XCTAssertEqual(volume.capacityBytes, 21_474_836_480)
        XCTAssertEqual(volume.allocationBytes, 6_743_098_654)
        XCTAssertTrue(volume.isSparse)
        XCTAssertEqual(volume.id, "Production/Pi-hole.qcow2")
    }

    // MARK: - XML escaping

    /// A VM named `Tom & Jerry` must not produce a document libvirt rejects.
    func testBuilderEscapesMarkupInValues() {
        var builder = XMLBuilder()
        builder.open("domain", ["type": "kvm"])
        builder.element("name", text: "Tom & Jerry <test>")
        builder.close()

        XCTAssertTrue(builder.document.contains("<name>Tom &amp; Jerry &lt;test&gt;</name>"))
    }

    func testBuilderEscapesAttributeValues() {
        var builder = XMLBuilder()
        builder.empty("source", ["file": #"/tmp/a"b.qcow2"#])
        XCTAssertTrue(builder.document.contains("&quot;"))
    }

    func testBuilderRoundTripsThroughParser() throws {
        var builder = XMLBuilder()
        builder.open("domain", ["type": "kvm"])
        builder.element("name", text: "Tom & Jerry")
        builder.element("memory", text: "2097152", ["unit": "KiB"])
        builder.close()

        let root = try XMLNode.parse(builder.document)
        XCTAssertEqual(root["name"]?.trimmedText, "Tom & Jerry")
        XCTAssertEqual(libvirtBytes(from: root["memory"]), 2 * 1024 * 1024 * 1024)
    }
}

// MARK: - Fixtures

private enum Fixtures {
    /// Trimmed from `virsh dumpxml Pi-hole` on the live host: the elements the
    /// parser reads, kept verbatim including attribute quoting style.
    static let piHoleDomain = """
    <domain type='kvm' id='1'>
      <name>Pi-hole</name>
      <uuid>26b590fc-9534-42f6-b5ef-821121435bd7</uuid>
      <description>Pi-hole DNS server</description>
      <memory unit='KiB'>2097152</memory>
      <currentMemory unit='KiB'>2097152</currentMemory>
      <vcpu placement='static'>1</vcpu>
      <os>
        <type arch='x86_64' machine='pc-q35-7.2'>hvm</type>
      </os>
      <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
          <source file='/srv/dev-disk-by-uuid-56c27fbb-fa6a-4220-b42b-beb672d3cec1/KVM/Production/Pi-hole.qcow2' index='1'/>
          <backingStore/>
          <target dev='vda' bus='virtio'/>
          <boot order='1'/>
          <alias name='virtio-disk0'/>
        </disk>
        <interface type='bridge'>
          <mac address='52:54:00:57:2f:0c'/>
          <source bridge='br0'/>
          <target dev='vnet0'/>
          <model type='virtio'/>
          <alias name='net0'/>
        </interface>
        <graphics type='vnc' port='5900' autoport='yes' listen='0.0.0.0'>
          <listen type='address' address='0.0.0.0'/>
        </graphics>
        <graphics type='spice' port='5901' autoport='yes' listen='0.0.0.0'>
          <listen type='address' address='0.0.0.0'/>
          <image compression='off'/>
        </graphics>
        <video>
          <model type='virtio' heads='1' primary='yes'/>
        </video>
      </devices>
    </domain>
    """

    /// Shape of `virsh snapshot-dumpxml`, matching the snapshot the host
    /// reports for Pi-hole.
    static let snapshot = """
    <domainsnapshot>
      <name>1775070450</name>
      <description>2026.04.01 21:07:30 :: running (1775070450)</description>
      <state>running</state>
      <creationTime>1775070450</creationTime>
      <parent>
        <name>1775070000</name>
      </parent>
    </domainsnapshot>
    """

    /// Sizes match what the host reports for the Production pool.
    static let pool = """
    <pool type='dir'>
      <name>Production</name>
      <uuid>9f1a4f1e-1f2b-4c3d-8e5f-0a1b2c3d4e5f</uuid>
      <capacity unit='bytes'>11904911519744</capacity>
      <allocation unit='bytes'>2387372220416</allocation>
      <available unit='bytes'>9517539299328</available>
      <target>
        <path>/srv/dev-disk-by-uuid-56c27fbb-fa6a-4220-b42b-beb672d3cec1/KVM/Production</path>
      </target>
    </pool>
    """

    static let volume = """
    <volume type='file'>
      <name>Pi-hole.qcow2</name>
      <capacity unit='bytes'>21474836480</capacity>
      <allocation unit='bytes'>6743098654</allocation>
      <target>
        <path>/srv/dev-disk-by-uuid-56c27fbb-fa6a-4220-b42b-beb672d3cec1/KVM/Production/Pi-hole.qcow2</path>
        <format type='qcow2'/>
      </target>
    </volume>
    """
}
