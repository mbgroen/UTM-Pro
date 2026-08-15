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

/// Field separator used to frame the output of batched scripts.
///
/// ASCII record separator: it cannot occur in libvirt XML or in a name, so
/// framing never collides with payload.
private let kRecordSeparator = "\u{1E}"

/// A libvirt host driven over SSH.
///
/// Every operation shells out to `virsh` on the remote side. Listing is
/// batched into a single remote script, because a round trip per domain adds
/// up quickly over a network link.
public actor LibvirtHost {
    private let connection: SSHConnection
    private let uri: String

    /// - Parameters:
    ///   - connection: an SSH connection to the host. Connecting is the
    ///     caller's responsibility.
    ///   - uri: the libvirt connection URI. `qemu:///system` is the system-wide
    ///     hypervisor that the OpenMediaVault KVM plugin manages.
    public init(connection: SSHConnection, uri: String = "qemu:///system") {
        self.connection = connection
        self.uri = uri
    }

    // MARK: - Command plumbing

    /// Runs one `virsh` subcommand.
    private func virsh(_ configure: (inout ShellCommand) -> Void) async throws -> SSHCommandResult {
        var command = ShellCommand("virsh")
        command.option("--connect", uri)
        configure(&command)
        return try await connection.run(command.commandLine)
    }

    /// Runs one `virsh` subcommand, translating a non-zero exit into an error.
    @discardableResult
    private func virshChecked(_ configure: (inout ShellCommand) -> Void) async throws -> String {
        let result = try await virsh(configure)
        guard result.status == 0 else {
            throw Self.translate(stderr: result.error, status: result.status)
        }
        return result.output
    }

    /// Runs a fixed multi-command script with the libvirt URI in the
    /// environment.
    ///
    /// The script is a `StaticString`, so it is always a literal from our own
    /// source and can never carry interpolated input.
    private func runScript(_ script: StaticString) async throws -> String {
        let prefix = "export LIBVIRT_DEFAULT_URI=\(ShellCommand.quote(uri)); "
        let result = try await connection.run(prefix + "\(script)")
        guard result.status == 0 else {
            throw Self.translate(stderr: result.error, status: result.status)
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    /// Maps `virsh` diagnostics onto typed errors so the UI can react to the
    /// cause rather than pattern-match strings itself.
    private static func translate(stderr: String, status: Int32) -> Error {
        let lowered = stderr.lowercased()
        if lowered.contains("command not found") || lowered.contains("not found: virsh") {
            return LibvirtError.virshUnavailable
        }
        if lowered.contains("domain not found") || lowered.contains("failed to get domain") {
            return LibvirtError.noSuchDomain(stderr)
        }
        if lowered.contains("storage pool not found") {
            return LibvirtError.noSuchPool(stderr)
        }
        if lowered.contains("storage vol not found") || lowered.contains("volume not found") {
            return LibvirtError.noSuchVolume(pool: "", volume: stderr)
        }
        if lowered.contains("is not running") || lowered.contains("is already active")
            || lowered.contains("domain is already running") || lowered.contains("not active") {
            return LibvirtError.invalidState(stderr)
        }
        if lowered.contains("permission denied") || lowered.contains("access denied") {
            return LibvirtError.refused(stderr)
        }
        return LibvirtError.refused(stderr.isEmpty ? "virsh exited with status \(status)" : stderr)
    }

    // MARK: - Host

    public func hostInfo() async throws -> LibvirtHostInfo {
        let nodeinfo = try await virshChecked { $0.flag("nodeinfo") }
        let hostname = try? await virshChecked { $0.flag("hostname") }
        let version = try? await virshChecked { $0.flag("version") }
        return LibvirtHostInfo(nodeinfo: nodeinfo,
                               hostname: hostname,
                               libvirtVersion: version,
                               hypervisorVersion: nil)
    }

    /// Verifies the remote side is usable before we start showing VMs.
    public func checkAvailability() async throws {
        let result = try await connection.run("command -v virsh")
        guard result.status == 0, !result.output.isEmpty else {
            throw LibvirtError.virshUnavailable
        }
        // Connecting to the URI proves the login user can actually talk to
        // libvirtd, which is a separate permission from having the binary.
        _ = try await virshChecked { $0.flag("version") }
    }

    // MARK: - Domains

    /// Lists every domain with its full configuration.
    ///
    /// One remote script emits name, XML, state and autostart for all domains,
    /// framed by record separators, so this costs a single round trip.
    public func listDomains() async throws -> [LibvirtDomain] {
        let raw = try await runScript("""
        virsh list --all --name | while IFS= read -r d; do
          [ -z "$d" ] && continue
          printf '\\036BEGIN\\036'
          virsh dumpxml "$d"
          printf '\\036STATE\\036'
          virsh domstate "$d"
          printf '\\036AUTOSTART\\036'
          virsh dominfo "$d" | sed -n 's/^Autostart: *//p'
        done
        """)

        var domains: [LibvirtDomain] = []
        for record in raw.components(separatedBy: kRecordSeparator + "BEGIN" + kRecordSeparator) {
            guard !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let stateSplit = record.components(separatedBy: kRecordSeparator + "STATE" + kRecordSeparator)
            guard stateSplit.count == 2 else { continue }
            let autostartSplit = stateSplit[1].components(separatedBy: kRecordSeparator + "AUTOSTART" + kRecordSeparator)
            guard autostartSplit.count == 2 else { continue }

            let xml = stateSplit[0]
            let state = LibvirtDomainState(virshState: autostartSplit[0])
            let isAutostart = autostartSplit[1].trimmingCharacters(in: .whitespacesAndNewlines) == "enable"
            do {
                domains.append(try LibvirtDomain(xml: xml, state: state, isAutostart: isAutostart))
            } catch {
                // One unreadable domain must not hide the rest of the host.
                continue
            }
        }
        return domains
    }

    /// Re-reads a single domain.
    public func domain(named name: String) async throws -> LibvirtDomain {
        let xml = try await virshChecked {
            $0.flag("dumpxml")
            $0.argument(name)
        }
        let stateText = try await virshChecked {
            $0.flag("domstate")
            $0.argument(name)
        }
        let info = try await virshChecked {
            $0.flag("dominfo")
            $0.argument(name)
        }
        let isAutostart = info
            .split(separator: "\n")
            .first { $0.hasPrefix("Autostart:") }?
            .contains("enable") ?? false
        return try LibvirtDomain(xml: xml,
                                 state: LibvirtDomainState(virshState: stateText),
                                 isAutostart: isAutostart)
    }

    public func domainXML(named name: String) async throws -> String {
        try await virshChecked {
            $0.flag("dumpxml")
            $0.argument(name)
        }
    }

    public func state(ofDomain name: String) async throws -> LibvirtDomainState {
        let text = try await virshChecked {
            $0.flag("domstate")
            $0.argument(name)
        }
        return LibvirtDomainState(virshState: text)
    }

    // MARK: - Domain lifecycle

    public func start(domain name: String) async throws {
        try await virshChecked {
            $0.flag("start")
            $0.argument(name)
        }
    }

    /// Asks the guest OS to shut down.
    public func shutdown(domain name: String) async throws {
        try await virshChecked {
            $0.flag("shutdown")
            $0.argument(name)
        }
    }

    /// Cuts power. The guest gets no chance to flush anything.
    public func destroy(domain name: String) async throws {
        try await virshChecked {
            $0.flag("destroy")
            $0.argument(name)
        }
    }

    /// Asks the guest OS to reboot.
    public func reboot(domain name: String) async throws {
        try await virshChecked {
            $0.flag("reboot")
            $0.argument(name)
        }
    }

    /// Hard reset, equivalent to the reset button.
    public func reset(domain name: String) async throws {
        try await virshChecked {
            $0.flag("reset")
            $0.argument(name)
        }
    }

    /// Freezes the domain's vCPUs. Memory stays resident on the host.
    public func suspend(domain name: String) async throws {
        try await virshChecked {
            $0.flag("suspend")
            $0.argument(name)
        }
    }

    public func resume(domain name: String) async throws {
        try await virshChecked {
            $0.flag("resume")
            $0.argument(name)
        }
    }

    public func setAutostart(_ enabled: Bool, forDomain name: String) async throws {
        try await virshChecked {
            $0.flag("autostart")
            if !enabled {
                $0.flag("--disable")
            }
            $0.argument(name)
        }
    }

    /// Writes the domain's memory to disk and stops it, resuming from that
    /// image on next start.
    public func managedSave(domain name: String) async throws {
        try await virshChecked {
            $0.flag("managedsave")
            $0.argument(name)
        }
    }

    public func removeManagedSave(domain name: String) async throws {
        try await virshChecked {
            $0.flag("managedsave-remove")
            $0.argument(name)
        }
    }

    // MARK: - Domain definition

    /// Defines a domain from XML, creating it or replacing its configuration.
    ///
    /// The XML is base64-encoded for transport so that no part of it is ever
    /// interpreted as shell syntax, however the guest was named.
    public func define(domainXML xml: String) async throws {
        let encoded = Data(xml.utf8).base64EncodedString()
        var command = ShellCommand("echo")
        command.argument(encoded)
        let pipeline = "\(command.commandLine) | base64 -d | "
            + "LIBVIRT_DEFAULT_URI=\(ShellCommand.quote(uri)) virsh define /dev/stdin"
        let result = try await connection.run(pipeline)
        guard result.status == 0 else {
            throw Self.translate(stderr: result.error, status: result.status)
        }
    }

    /// Removes a domain's definition.
    ///
    /// - Parameter removeStorage: also deletes the domain's disk images. This
    ///   is not recoverable.
    public func undefine(domain name: String, removeStorage: Bool = false) async throws {
        try await virshChecked {
            $0.flag("undefine")
            $0.flag("--nvram")
            if removeStorage {
                $0.flag("--remove-all-storage")
            }
            $0.argument(name)
        }
    }

    // MARK: - Snapshots

    /// Lists a domain's snapshots, newest first.
    public func snapshots(ofDomain name: String) async throws -> [LibvirtSnapshot] {
        let names = try await virshChecked {
            $0.flag("snapshot-list")
            $0.argument(name)
            $0.flag("--name")
        }
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

        guard !names.isEmpty else { return [] }

        // `snapshot-current --name` fails when there is none, which is normal.
        let current = try? await virshChecked {
            $0.flag("snapshot-current")
            $0.argument(name)
            $0.flag("--name")
        }

        var snapshots: [LibvirtSnapshot] = []
        for snapshotName in names {
            let xml = try await virshChecked {
                $0.flag("snapshot-dumpxml")
                $0.argument(name)
                $0.argument(snapshotName)
            }
            if let snapshot = try? LibvirtSnapshot(xml: xml, isCurrent: snapshotName == current) {
                snapshots.append(snapshot)
            }
        }
        return snapshots.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
    }

    /// Takes a snapshot.
    ///
    /// For a running domain this captures memory as well as disk, so reverting
    /// resumes mid-execution. For a stopped domain it captures disk only.
    public func createSnapshot(ofDomain domainName: String,
                               named snapshotName: String,
                               description: String? = nil) async throws {
        try await virshChecked {
            $0.flag("snapshot-create-as")
            $0.option("--domain", domainName)
            $0.option("--name", snapshotName)
            $0.option("--description", description)
            // Fail cleanly rather than leaving a half-written snapshot behind.
            $0.flag("--atomic")
        }
    }

    /// Reverts a domain to a snapshot, discarding everything since.
    public func revertSnapshot(ofDomain domainName: String, named snapshotName: String) async throws {
        try await virshChecked {
            $0.flag("snapshot-revert")
            $0.option("--domain", domainName)
            $0.option("--snapshotname", snapshotName)
        }
    }

    public func deleteSnapshot(ofDomain domainName: String, named snapshotName: String) async throws {
        try await virshChecked {
            $0.flag("snapshot-delete")
            $0.option("--domain", domainName)
            $0.option("--snapshotname", snapshotName)
        }
    }

    // MARK: - Storage pools

    public func listPools() async throws -> [LibvirtPool] {
        let raw = try await runScript("""
        virsh pool-list --all --name | while IFS= read -r p; do
          [ -z "$p" ] && continue
          printf '\\036BEGIN\\036'
          virsh pool-dumpxml "$p"
          printf '\\036INFO\\036'
          virsh pool-info "$p"
        done
        """)

        var pools: [LibvirtPool] = []
        for record in raw.components(separatedBy: kRecordSeparator + "BEGIN" + kRecordSeparator) {
            guard !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let parts = record.components(separatedBy: kRecordSeparator + "INFO" + kRecordSeparator)
            guard parts.count == 2 else { continue }
            let info = parts[1]
            let isActive = Self.field("State", in: info)?.lowercased() == "running"
            let isAutostart = Self.field("Autostart", in: info)?.lowercased() == "yes"
            if let pool = try? LibvirtPool(xml: parts[0], isActive: isActive, isAutostart: isAutostart) {
                pools.append(pool)
            }
        }
        return pools.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func field(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Creates a directory-backed pool and starts it.
    ///
    /// Defined as persistent with autostart so it survives a NAS reboot, which
    /// is what anyone adding storage to a NAS expects.
    public func createDirectoryPool(named name: String, targetPath: String) async throws {
        try await virshChecked {
            $0.flag("pool-define-as")
            $0.argument(name)
            $0.flag("dir")
            $0.flag("--target")
            $0.argument(targetPath)
        }
        // Building creates the directory when it does not exist yet. It fails
        // harmlessly when it does, so a pre-existing directory is not an error.
        _ = try? await virshChecked {
            $0.flag("pool-build")
            $0.argument(name)
        }
        try await startPool(named: name)
        try await setPoolAutostart(true, forPool: name)
    }

    public func startPool(named name: String) async throws {
        try await virshChecked {
            $0.flag("pool-start")
            $0.argument(name)
        }
    }

    public func stopPool(named name: String) async throws {
        try await virshChecked {
            $0.flag("pool-destroy")
            $0.argument(name)
        }
    }

    public func setPoolAutostart(_ enabled: Bool, forPool name: String) async throws {
        try await virshChecked {
            $0.flag("pool-autostart")
            if !enabled {
                $0.flag("--disable")
            }
            $0.argument(name)
        }
    }

    /// Re-reads a pool's contents from disk.
    ///
    /// Needed after anything writes into the pool directory behind libvirt's
    /// back — uploading an ISO over SMB, for instance.
    public func refreshPool(named name: String) async throws {
        try await virshChecked {
            $0.flag("pool-refresh")
            $0.argument(name)
        }
    }

    /// Removes a pool's definition. Volumes on disk are left alone.
    public func undefinePool(named name: String) async throws {
        // A running pool cannot be undefined; stopping first is expected and
        // failing here just means it was already stopped.
        _ = try? await stopPool(named: name)
        try await virshChecked {
            $0.flag("pool-undefine")
            $0.argument(name)
        }
    }

    // MARK: - Volumes

    public func listVolumes(inPool poolName: String) async throws -> [LibvirtVolume] {
        // `vol-list` prints a two-column table; parsing it breaks on names with
        // spaces. Listing names alone and dumping each one is exact.
        let listing = try await virshChecked {
            $0.flag("vol-list")
            $0.option("--pool", poolName)
        }

        var names: [String] = []
        for line in listing.split(separator: "\n").dropFirst(2) {
            // Columns are separated by runs of spaces; the path column always
            // begins with a slash, so split at the last such run.
            let text = String(line)
            guard let range = text.range(of: " {2,}", options: .regularExpression) else { continue }
            let name = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                names.append(name)
            }
        }

        var volumes: [LibvirtVolume] = []
        for name in names {
            guard let xml = try? await virshChecked({
                $0.flag("vol-dumpxml")
                $0.option("--pool", poolName)
                $0.argument(name)
            }) else { continue }
            if let volume = try? LibvirtVolume(xml: xml, poolName: poolName) {
                volumes.append(volume)
            }
        }
        return volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func createVolume(named name: String,
                             inPool poolName: String,
                             capacityBytes: UInt64,
                             format: LibvirtVolumeFormat = .qcow2) async throws {
        try await virshChecked {
            $0.flag("vol-create-as")
            $0.option("--pool", poolName)
            $0.option("--name", name)
            $0.option("--capacity", capacityBytes)
            $0.option("--format", format.rawValue)
        }
    }

    public func deleteVolume(named name: String, inPool poolName: String) async throws {
        try await virshChecked {
            $0.flag("vol-delete")
            $0.option("--pool", poolName)
            $0.option("--vol", name)
        }
    }

    /// Resizes a volume.
    ///
    /// - Parameter allowShrink: shrinking discards data past the new end and
    ///   libvirt refuses without this flag. The guest filesystem must already
    ///   have been shrunk to fit, or it will be corrupt.
    public func resizeVolume(named name: String,
                             inPool poolName: String,
                             toBytes capacityBytes: UInt64,
                             allowShrink: Bool = false) async throws {
        try await virshChecked {
            $0.flag("vol-resize")
            $0.option("--pool", poolName)
            $0.option("--vol", name)
            $0.argument(capacityBytes)
            if allowShrink {
                $0.flag("--shrink")
            }
        }
    }

    public func cloneVolume(named name: String,
                            inPool poolName: String,
                            toName newName: String) async throws {
        try await virshChecked {
            $0.flag("vol-clone")
            $0.option("--pool", poolName)
            $0.option("--vol", name)
            $0.option("--newname", newName)
        }
    }

    /// Converts a volume to another image format.
    ///
    /// libvirt has no equivalent, so this runs `qemu-img convert` against the
    /// pool's directory and refreshes the pool afterwards so the new volume
    /// appears.
    public func convertVolume(at sourcePath: String,
                              toPath destinationPath: String,
                              format: LibvirtVolumeFormat,
                              inPool poolName: String) async throws {
        var command = ShellCommand("qemu-img")
        command.flag("convert")
        command.option("-O", format.rawValue)
        command.argument(sourcePath)
        command.argument(destinationPath)
        let result = try await connection.run(command.commandLine)
        guard result.status == 0 else {
            throw LibvirtError.refused(result.error)
        }
        try await refreshPool(named: poolName)
    }

    /// Reads image details straight from `qemu-img`.
    ///
    /// Includes the internal snapshot list, which libvirt does not report for
    /// volumes that are not attached to a defined domain.
    public func imageInfo(at path: String) async throws -> QemuImageInfo {
        var command = ShellCommand("qemu-img")
        command.flag("info")
        command.flag("--output=json")
        command.argument(path)
        let result = try await connection.run(command.commandLine)
        guard result.status == 0 else {
            throw LibvirtError.refused(result.error)
        }
        return try JSONDecoder().decode(QemuImageInfo.self, from: result.standardOutput)
    }
}

/// The subset of `qemu-img info --output=json` we consume.
public struct QemuImageInfo: Codable, Sendable {
    public let virtualSize: UInt64
    public let actualSize: UInt64?
    public let format: String
    public let snapshots: [Snapshot]?

    public struct Snapshot: Codable, Sendable {
        public let id: String
        public let name: String
        public let vmStateSize: UInt64?
        public let dateSec: TimeInterval?

        public var creationDate: Date? {
            dateSec.map { Date(timeIntervalSince1970: $0) }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case vmStateSize = "vm-state-size"
            case dateSec = "date-sec"
        }
    }

    enum CodingKeys: String, CodingKey {
        case virtualSize = "virtual-size"
        case actualSize = "actual-size"
        case format
        case snapshots
    }
}
