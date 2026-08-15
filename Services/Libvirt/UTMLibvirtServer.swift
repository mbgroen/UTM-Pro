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

import Combine
import Foundation
import LibvirtKit

/// One configured libvirt host, its connection, and the VMs it holds.
@MainActor
final class UTMLibvirtServer: ObservableObject, Identifiable {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        /// The connection failed; the message is shown in the sidebar.
        case failed(String)
        /// The host key does not match what we pinned, or has never been
        /// pinned. Requires the user to decide.
        case untrustedHostKey(fingerprint: String, isChange: Bool)

        var isConnected: Bool {
            self == .connected
        }
    }

    @Published private(set) var settings: UTMLibvirtServerSettings

    @Published private(set) var connectionState: ConnectionState = .disconnected

    /// The domains on this host, wrapped for the UI.
    @Published private(set) var virtualMachines: [VMData] = []

    @Published private(set) var pools: [LibvirtPool] = []

    @Published private(set) var hostInfo: LibvirtHostInfo?

    private var connection: SSHConnection?
    private var host: LibvirtHost?

    /// Console tunnels currently open, keyed by domain name, so repeated
    /// console opens reuse one forward instead of stacking them up.
    private var consoleTunnels: [String: Int] = [:]

    var id: UUID { settings.id }

    init(settings: UTMLibvirtServerSettings) {
        self.settings = settings
    }

    /// The libvirt facade. Only valid once connected.
    var libvirt: LibvirtHost {
        get throws {
            guard let host else {
                throw UTMLibvirtServerError.notConnected
            }
            return host
        }
    }

    func update(settings: UTMLibvirtServerSettings) {
        self.settings = settings
    }

    // MARK: - Connecting

    /// Connects and loads the host's domains and pools.
    ///
    /// - Parameter trustingHostKey: accept and pin whatever host key the
    ///   server presents. Only pass true straight after the user confirmed a
    ///   fingerprint shown to them.
    func connect(trustingHostKey: Bool = false) async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting

        do {
            let credential = try UTMLibvirtCredentialStore.credential(for: settings)
            let hadPinnedKey = settings.hostKeyFingerprint != nil
            let policy: SSHHostKeyPolicy
            if let fingerprint = settings.hostKeyFingerprint, !trustingHostKey {
                policy = .pinned(SSHHostKeyFingerprint(value: fingerprint))
            } else {
                policy = .trustOnFirstUse
            }

            let destination = SSHDestination(host: settings.host,
                                             port: settings.port,
                                             username: settings.username,
                                             credential: credential,
                                             hostKeyPolicy: policy)
            let connection = SSHConnection(destination: destination)
            try await connection.connect()

            let presented = await connection.presentedHostKey
            if trustingHostKey || !hadPinnedKey {
                // First connection, or the user just accepted a new key.
                if let presented {
                    settings.hostKeyFingerprint = presented.value
                }
            }

            let host = LibvirtHost(connection: connection, uri: settings.uri)
            try await host.checkAvailability()

            self.connection = connection
            self.host = host
            connectionState = .connected

            await refresh()
        } catch let error as SSHError {
            if case .hostKeyMismatch(_, let actual) = error {
                connectionState = .untrustedHostKey(fingerprint: actual, isChange: true)
            } else {
                connectionState = .failed(error.localizedDescription)
            }
            await teardown()
        } catch {
            connectionState = .failed(error.localizedDescription)
            await teardown()
        }
    }

    func disconnect() async {
        await teardown()
        connectionState = .disconnected
        virtualMachines = []
        pools = []
        hostInfo = nil
    }

    private func teardown() async {
        if let connection {
            await connection.disconnect()
        }
        connection = nil
        host = nil
        consoleTunnels = [:]
    }

    // MARK: - Refreshing

    /// Re-reads domains and pools from the host, preserving existing VM
    /// objects so open sessions and SwiftUI selection survive a refresh.
    func refresh() async {
        guard let host else { return }
        do {
            let domains = try await host.listDomains()
            // Reuse the existing wrapper objects: replacing them would drop
            // SwiftUI's selection and detach any open console session.
            let existing = virtualMachines.reduce(into: [UUID: VMData]()) { result, data in
                if let wrapped = data.wrapped as? UTMLibvirtVirtualMachine {
                    result[wrapped.id] = data
                }
            }

            virtualMachines = domains.map { domain in
                if let data = existing[domain.uuid],
                   let vm = data.wrapped as? UTMLibvirtVirtualMachine {
                    vm.update(from: domain)
                    return data
                } else {
                    return VMData(wrapping: UTMLibvirtVirtualMachine(server: self, domain: domain))
                }
            }

            pools = try await host.listPools()
            hostInfo = try? await host.hostInfo()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Console

    /// Resolves the address the console should connect to.
    ///
    /// When tunnelling is on this opens (or reuses) an SSH port forward and
    /// returns a loopback address, so the console never traverses the network
    /// unencrypted — which matters because these consoles routinely listen on
    /// every interface with no password.
    func consoleAddress(for vm: UTMLibvirtVirtualMachine) async throws -> (host: String, port: Int) {
        guard let graphics = vm.domainInfo.preferredGraphics else {
            throw UTMLibvirtVirtualMachineError.noConsole
        }
        guard let port = graphics.port else {
            // The device exists but libvirt has not assigned it a port, which
            // is a different problem from having no console at all.
            throw UTMLibvirtVirtualMachineError.consolePortUnavailable
        }
        guard settings.tunnelConsole else {
            return (settings.host, port)
        }
        guard let connection else {
            throw UTMLibvirtServerError.notConnected
        }
        if let existing = consoleTunnels[vm.domainName] {
            return ("127.0.0.1", existing)
        }
        // The far end of the tunnel is loopback *on the NAS*, so the console
        // traffic never leaves that machine unencrypted either.
        let localPort = try await connection.forwardLocalPort(to: "127.0.0.1", remotePort: port)
        consoleTunnels[vm.domainName] = localPort
        return ("127.0.0.1", localPort)
    }

    /// Starts `virsh console` for a domain on this host.
    ///
    /// `--force` takes the console even when another client is already
    /// attached. Without it, a session someone forgot to close on the NAS
    /// blocks every later attempt with an error that does not explain itself.
    func openSerialConsole(forDomain name: String,
                           onOutput: @escaping @Sendable (Data) -> Void,
                           onClose: @escaping @Sendable () -> Void) async throws -> SSHShellSession {
        guard let connection else {
            throw UTMLibvirtServerError.notConnected
        }
        var command = ShellCommand("virsh")
        command.option("--connect", settings.uri)
        command.flag("console")
        command.argument(name)
        command.flag("--force")
        return try await connection.openShell(command: command.commandLine,
                                              onOutput: onOutput,
                                              onClose: onClose)
    }

    /// Closes a console tunnel once its session ends.
    func closeConsole(for vm: UTMLibvirtVirtualMachine) async {
        guard let localPort = consoleTunnels.removeValue(forKey: vm.domainName),
              let connection else {
            return
        }
        await connection.closeForward(localPort: localPort)
    }

    // MARK: - Storage

    func volumes(inPool poolName: String) async throws -> [LibvirtVolume] {
        try await libvirt.listVolumes(inPool: poolName)
    }

    func refreshPools() async throws {
        pools = try await libvirt.listPools()
    }

    /// Creates a directory-backed pool and starts it.
    func createPool(named name: String, targetPath: String) async throws {
        try await libvirt.createDirectoryPool(named: name, targetPath: targetPath)
        try await refreshPools()
    }

    func startPool(named name: String) async throws {
        try await libvirt.startPool(named: name)
        try await refreshPools()
    }

    func stopPool(named name: String) async throws {
        try await libvirt.stopPool(named: name)
        try await refreshPools()
    }

    func setPoolAutostart(_ enabled: Bool, forPool name: String) async throws {
        try await libvirt.setPoolAutostart(enabled, forPool: name)
        try await refreshPools()
    }

    /// Re-reads a pool's contents from disk.
    ///
    /// Needed whenever something writes into the pool directory behind
    /// libvirt's back — an ISO copied in over SMB, for instance.
    func rescanPool(named name: String) async throws {
        try await libvirt.refreshPool(named: name)
        try await refreshPools()
    }

    /// Removes a pool's definition. The volumes on disk are untouched.
    func undefinePool(named name: String) async throws {
        try await libvirt.undefinePool(named: name)
        try await refreshPools()
    }

    // MARK: - Volumes

    func createVolume(named name: String,
                      inPool poolName: String,
                      capacityBytes: UInt64,
                      format: LibvirtVolumeFormat) async throws {
        try await libvirt.createVolume(named: name,
                                       inPool: poolName,
                                       capacityBytes: capacityBytes,
                                       format: format)
        try await refreshPools()
    }

    func resizeVolume(named name: String,
                      inPool poolName: String,
                      toBytes bytes: UInt64,
                      allowShrink: Bool) async throws {
        try await libvirt.resizeVolume(named: name,
                                       inPool: poolName,
                                       toBytes: bytes,
                                       allowShrink: allowShrink)
        try await refreshPools()
    }

    func cloneVolume(named name: String, inPool poolName: String, toName newName: String) async throws {
        try await libvirt.cloneVolume(named: name, inPool: poolName, toName: newName)
        try await refreshPools()
    }

    func convertVolume(at sourcePath: String,
                       toPath destinationPath: String,
                       format: LibvirtVolumeFormat,
                       inPool poolName: String) async throws {
        try await libvirt.convertVolume(at: sourcePath,
                                        toPath: destinationPath,
                                        format: format,
                                        inPool: poolName)
        try await refreshPools()
    }

    func deleteVolume(named name: String, inPool poolName: String) async throws {
        try await libvirt.deleteVolume(named: name, inPool: poolName)
        try await refreshPools()
    }

    // MARK: - Creating a VM

    /// Creates a disk and defines a domain around it.
    ///
    /// The volume is created first because the domain XML has to name its
    /// path. If defining the domain then fails, the orphaned volume is removed
    /// rather than left behind for someone to puzzle over later.
    func createVirtualMachine(name: String,
                              notes: String?,
                              memoryBytes: UInt64,
                              vcpuCount: Int,
                              poolName: String,
                              volumeName: String,
                              diskBytes: UInt64,
                              diskFormat: LibvirtVolumeFormat,
                              isoPath: String?,
                              network: LibvirtDomainTemplate.Network,
                              startImmediately: Bool) async throws {
        let host = try libvirt

        try await host.createVolume(named: volumeName,
                                    inPool: poolName,
                                    capacityBytes: diskBytes,
                                    format: diskFormat)

        let volumes = try await host.listVolumes(inPool: poolName)
        guard let volume = volumes.first(where: { $0.name == volumeName }) else {
            throw UTMLibvirtServerError.volumeMissingAfterCreate(volumeName)
        }

        let template = LibvirtDomainTemplate(name: name,
                                             notes: notes,
                                             memoryBytes: memoryBytes,
                                             vcpuCount: vcpuCount,
                                             diskPath: volume.path,
                                             diskFormat: diskFormat,
                                             isoPath: isoPath,
                                             network: network)
        do {
            try await host.define(domainXML: template.domainXML())
        } catch {
            // Leaving a disk behind for a VM that does not exist is worse than
            // the original failure.
            try? await host.deleteVolume(named: volumeName, inPool: poolName)
            throw error
        }

        if startImmediately {
            try? await host.start(domain: name)
        }

        await refresh()
    }

    /// Duplicates a domain, giving the copy its own disks.
    ///
    /// The disks are copied rather than shared. Two domains booting the same
    /// image corrupt it, and libvirt will not stop you defining that — so a
    /// "clone" that shared storage would be a trap rather than a shortcut.
    func cloneVirtualMachine(_ vm: UTMLibvirtVirtualMachine,
                             toName newName: String,
                             inPool poolName: String) async throws {
        let host = try libvirt
        guard vm.state == .stopped else {
            throw UTMLibvirtServerError.cloneRequiresStoppedVM
        }

        var copiedVolumes: [String] = []
        do {
            // Copy each disk into the target pool under the new VM's name.
            var diskPaths: [String] = []
            for (index, target) in vm.domainInfo.diskTargets.sorted().enumerated() {
                guard let sourcePath = vm.domainInfo.diskPaths[target] else { continue }
                let ext = (sourcePath as NSString).pathExtension
                let suffix = index == 0 ? "" : "-\(target)"
                let volumeName = ext.isEmpty ? "\(newName)\(suffix)" : "\(newName)\(suffix).\(ext)"
                let directory = try await poolPath(named: poolName, host: host)
                let destination = (directory as NSString).appendingPathComponent(volumeName)
                try await host.convertVolume(at: sourcePath,
                                             toPath: destination,
                                             format: ext == "raw" ? .raw : .qcow2,
                                             inPool: poolName)
                copiedVolumes.append(volumeName)
                diskPaths.append(destination)
            }
            guard let bootDisk = diskPaths.first else {
                throw UTMLibvirtServerError.cloneHasNoDisk
            }

            let template = LibvirtDomainTemplate(
                name: newName,
                notes: vm.config.information.notes,
                architecture: vm.domainInfo.architecture ?? "x86_64",
                machine: vm.domainInfo.machine ?? "q35",
                memoryBytes: UInt64(max(1, vm.config.system.memorySize)) * 1024 * 1024,
                vcpuCount: vm.config.system.cpuCount,
                diskPath: bootDisk,
                network: networkTemplate(from: vm)
            )
            try await host.define(domainXML: template.domainXML())

            // Any disk beyond the first is attached separately.
            for (index, path) in diskPaths.enumerated() where index > 0 {
                let target = LibvirtHost.nextTargetDevice(
                    after: (0..<index).map { LibvirtHost.nextTargetDevice(after: Array(repeating: "", count: $0)) }
                )
                try await host.attachDisk(toDomain: newName,
                                          volumePath: path,
                                          targetDevice: target)
            }
        } catch {
            // Copies of a multi-gigabyte disk are not something to leave lying
            // around after a failure.
            for volumeName in copiedVolumes {
                try? await host.deleteVolume(named: volumeName, inPool: poolName)
            }
            throw error
        }

        await refresh()
        try? await refreshPools()
    }

    private func poolPath(named name: String, host: LibvirtHost) async throws -> String {
        if let pool = pools.first(where: { $0.name == name }), let path = pool.targetPath {
            return path
        }
        let refreshed = try await host.listPools()
        guard let path = refreshed.first(where: { $0.name == name })?.targetPath else {
            throw UTMLibvirtServerError.poolPathUnknown(name)
        }
        return path
    }

    /// Reuses the source VM's network attachment, with a fresh MAC.
    private func networkTemplate(from vm: UTMLibvirtVirtualMachine) -> LibvirtDomainTemplate.Network {
        guard let interface = vm.domainInfo.interfaces.first, let source = interface.source else {
            return .none
        }
        return interface.kind == "network" ? .virtualNetwork(source) : .bridge(source)
    }

    /// Removes a domain's definition.
    ///
    /// - Parameter removeStorage: also delete the domain's disk images. Off by
    ///   default, because undefining a VM is reversible if the disks survive
    ///   and permanent if they do not.
    func deleteVirtualMachine(_ vm: UTMLibvirtVirtualMachine, removeStorage: Bool) async throws {
        let host = try libvirt
        let name = vm.domainName

        // A running domain cannot be undefined, and cutting power without
        // saying so would look like the delete itself broke something.
        if vm.state != .stopped {
            try await host.destroy(domain: name)
        }
        await vm.disconnectConsole()
        try await host.undefine(domain: name, removeStorage: removeStorage)
        await refresh()
        try? await refreshPools()
    }

    /// Names of domains currently using a given image path.
    ///
    /// Deleting a volume another VM is booting from destroys that VM, and
    /// libvirt will not stop you, so the UI needs to be able to say so.
    func domainsUsing(volumePath path: String) -> [String] {
        virtualMachines.compactMap { data in
            guard let vm = data.wrapped as? UTMLibvirtVirtualMachine else { return nil }
            return vm.domainInfo.diskPaths.values.contains(path) ? vm.domainName : nil
        }
    }
}
