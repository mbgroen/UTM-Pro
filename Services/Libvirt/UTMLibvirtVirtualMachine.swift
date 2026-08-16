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
import QEMUKitInternal

/// How long to wait for the console to come up before giving up.
private let kConsoleConnectTimeout: TimeInterval = 15

/// A virtual machine running on a remote libvirt host.
///
/// Conforms to `UTMSpiceVirtualMachine` so it can reuse UTM's display stack:
/// the console is SPICE either way, and the only real difference is that the
/// connection goes to a host across the network rather than a local socket.
/// That protocol fixes the configuration type, so the domain is projected into
/// a `UTMQemuConfiguration` and the libvirt-only facts live in `domainInfo`.
@MainActor
final class UTMLibvirtVirtualMachine: UTMSpiceVirtualMachine {
    struct Capabilities: UTMVirtualMachineCapabilities {
        /// libvirt's `destroy` is a process kill in all but name.
        var supportsProcessKill: Bool { true }

        var supportsSnapshots: Bool { true }

        var supportsScreenshots: Bool { true }

        var supportsDisposibleMode: Bool { false }

        var supportsRecoveryMode: Bool { false }

        var supportsRemoteSession: Bool { false }
    }

    static let capabilities = Capabilities()

    /// The host this domain lives on.
    private let server: UTMLibvirtServer

    private(set) var config: UTMQemuConfiguration

    /// Everything about the domain that a QEMU configuration cannot express.
    private(set) var domainInfo: UTMLibvirtDomainInfo

    private(set) var registryEntry: UTMRegistryEntry

    var domainName: String { domainInfo.domainName }

    /// One compact line of facts for the sidebar.
    ///
    /// The machine type is the same long string on every VM of a host, so it
    /// fills the list without distinguishing anything. What tells VMs apart is
    /// their size and what they are doing.
    var remoteSummaryLabel: String {
        var parts: [String] = []
        if let architecture = domainInfo.architecture {
            parts.append(architecture)
        }
        parts.append(String(format: NSLocalizedString("%d CPU", comment: "UTMLibvirtVirtualMachine"),
                            domainInfo.vcpuCount))
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(config.system.memorySize) * 1024 * 1024,
                                               countStyle: .binary))
        return parts.joined(separator: " · ")
    }

    /// The local port a console tunnel is bound to, while one is open.
    private var tunnelPort: Int?

    // MARK: - UTMVirtualMachine plumbing

    /// A synthetic path. Remote domains have no local package, but the
    /// protocol and registry are both built around one.
    private(set) var pathUrl: URL

    private(set) var isShortcut: Bool = false

    private(set) var isRunningAsDisposible: Bool = false

    weak var delegate: (any UTMVirtualMachineDelegate)?

    var onConfigurationChange: (() -> Void)?

    var onStateChange: (() -> Void)?

    private(set) var state: UTMVirtualMachineState = .stopped {
        willSet {
            onStateChange?()
        }
        didSet {
            delegate?.virtualMachine(self, didTransitionToState: state)
        }
    }

    var screenshot: UTMVirtualMachineScreenshot? {
        willSet {
            onStateChange?()
        }
    }

    /// Snapshots need a disk that can hold them. Reported up front so the UI
    /// can disable the control rather than failing when the user tries.
    private(set) var snapshotUnsupportedError: Error?

    var isHeadless: Bool {
        !domainInfo.hasSupportedConsole
    }

    // MARK: - SPICE

    weak var ioServiceDelegate: UTMSpiceIODelegate? {
        didSet {
            if let ioService = ioService {
                ioService.delegate = ioServiceDelegate
            }
        }
    }

    private(set) var ioService: UTMSpiceIO? {
        didSet {
            oldValue?.delegate = nil
            ioService?.delegate = ioServiceDelegate
        }
    }

    var changeCursorRequestInProgress: Bool = false

    init(server: UTMLibvirtServer, domain: LibvirtDomain) {
        self.server = server
        self.config = UTMQemuConfiguration.projecting(domain: domain)
        self.domainInfo = UTMLibvirtDomainInfo(domain: domain, serverId: server.id)
        self.pathUrl = Self.syntheticPath(serverId: server.id, domainName: domain.name)
        self.registryEntry = UTMRegistry.shared.entry(uuid: domain.uuid,
                                                      name: domain.name,
                                                      path: self.pathUrl.path)
        self.state = Self.utmState(from: domain.state)
        self.snapshotUnsupportedError = domain.supportsInternalSnapshots
            ? nil
            : UTMLibvirtVirtualMachineError.noSnapshotCapableDisk
    }

    /// Not applicable: remote domains are never instantiated from a package.
    init(packageUrl: URL, configuration: UTMQemuConfiguration, isShortcut: Bool) throws {
        throw UTMVirtualMachineError.notImplemented
    }

    /// A stable, non-colliding pseudo-path used for registry identity.
    private static func syntheticPath(serverId: UUID, domainName: String) -> URL {
        URL(fileURLWithPath: "/libvirt")
            .appendingPathComponent(serverId.uuidString)
            .appendingPathComponent(domainName)
    }

    static func utmState(from state: LibvirtDomainState) -> UTMVirtualMachineState {
        switch state {
        case .running, .idle:
            return .started
        case .paused, .suspended:
            return .paused
        case .inShutdown:
            return .stopping
        case .shutOff, .crashed, .unknown:
            return .stopped
        }
    }

    /// Applies a freshly read domain to this VM.
    func update(from domain: LibvirtDomain) {
        config.update(projecting: domain, previous: domainInfo)
        domainInfo = UTMLibvirtDomainInfo(domain: domain, serverId: server.id)
        snapshotUnsupportedError = domain.supportsInternalSnapshots
            ? nil
            : UTMLibvirtVirtualMachineError.noSnapshotCapableDisk
        onConfigurationChange?()
        let newState = Self.utmState(from: domain.state)
        if newState != state {
            state = newState
        }
    }

    func reload(from packageUrl: URL?) throws {
        throw UTMVirtualMachineError.notImplemented
    }

    func updateConfigFromRegistry() {
        // Nothing local to reconcile.
    }

    func changeUuid(to uuid: UUID, name: String?, copyingEntry entry: UTMRegistryEntry?) {
        // The host assigns the UUID; we never reassign it.
    }

    func updateRegistryFromConfig() async throws {
        registryEntry.name = config.information.name
    }

    /// Applies configuration changes to the domain on its host.
    ///
    /// There is no package to write; "saving" a remote VM means reconciling
    /// the edited projection against libvirt. Only fields that were actually
    /// changed are sent, so saving an untouched VM costs nothing and cannot
    /// disturb settings this projection does not model.
    ///
    /// UTM only enables editing while a VM is stopped, which is also what
    /// libvirt requires for most of these.
    func save() async throws {
        let host = try server.libvirt
        let original = domainInfo

        if config.system.memorySize != original.memorySizeMib {
            let bytes = UInt64(max(1, config.system.memorySize)) * 1024 * 1024
            try await host.setMemory(ofDomain: original.domainName, bytes: bytes)
        }

        if config.system.cpuCount != original.vcpuCount {
            try await host.setVCPUs(ofDomain: original.domainName, count: config.system.cpuCount)
        }

        let notes = config.information.notes ?? ""
        if notes != (original.notes ?? "") {
            try await host.setDescription(ofDomain: original.domainName, text: notes)
        }

        try await applyNetworkChanges(host: host, original: original)

        // Renaming last: everything above addresses the domain by its old
        // name, and libvirt has no transaction to roll back into.
        let newName = config.information.name
        if newName != original.domainName, !newName.isEmpty {
            try await host.rename(domain: original.domainName, to: newName)
        }

        let refreshed = try await host.domain(named: newName.isEmpty ? original.domainName : newName)
        update(from: refreshed)
    }

    /// Re-points interfaces whose bridge changed.
    ///
    /// libvirt has no "change the bridge" operation: an interface is detached
    /// by MAC and a new one attached. Only interfaces that actually moved are
    /// touched, because detaching and re-attaching an unchanged one would give
    /// it a new MAC and break the guest's DHCP lease for no reason.
    private func applyNetworkChanges(host: LibvirtHost, original: UTMLibvirtDomainInfo) async throws {
        let originalSources = original.interfaceSources
        for (index, network) in config.networks.enumerated() {
            guard index < originalSources.count else { continue }
            guard let newSource = network.bridgeInterface,
                  !newSource.isEmpty,
                  newSource != originalSources[index] else { continue }
            guard index < original.interfaces.count,
                  let mac = original.interfaces[index].macAddress else { continue }

            try await host.detachInterface(fromDomain: original.domainName, macAddress: mac)
            try await host.attachInterface(toDomain: original.domainName,
                                           source: newSource,
                                           macAddress: mac)
        }
    }

    // MARK: - Disks

    /// Creates a volume in a pool and attaches it to this domain.
    func addDisk(named name: String,
                 inPool poolName: String,
                 capacityBytes: UInt64,
                 format: LibvirtVolumeFormat) async throws {
        let host = try server.libvirt
        try await host.createVolume(named: name,
                                    inPool: poolName,
                                    capacityBytes: capacityBytes,
                                    format: format)
        let volumes = try await host.listVolumes(inPool: poolName)
        guard let created = volumes.first(where: { $0.name == name }) else {
            throw UTMLibvirtVirtualMachineError.volumeNotFoundAfterCreate(name)
        }
        try await attachDisk(at: created.path, format: format, isCDROM: false)
    }

    /// Attaches a volume that already exists on the host.
    func attachDisk(at path: String,
                    format: LibvirtVolumeFormat,
                    isCDROM: Bool) async throws {
        let host = try server.libvirt
        let target = LibvirtHost.nextTargetDevice(after: domainInfo.diskTargets, isCDROM: isCDROM)
        try await host.attachDisk(toDomain: domainName,
                                  volumePath: path,
                                  targetDevice: target,
                                  format: format,
                                  isCDROM: isCDROM)
        let refreshed = try await host.domain(named: domainName)
        update(from: refreshed)
    }

    /// Detaches a disk. The image is left on the host.
    func removeDisk(targetDevice: String) async throws {
        let host = try server.libvirt
        try await host.detachDisk(fromDomain: domainName, targetDevice: targetDevice)
        let refreshed = try await host.domain(named: domainName)
        update(from: refreshed)
    }

    // MARK: - Lifecycle

    /// Runs a host operation, moving through a transient state and restoring
    /// the previous one if it fails, so a rejected command does not leave the
    /// row stuck on "Starting".
    private func operation(transitioningTo transient: UTMVirtualMachineState,
                           _ body: @escaping (LibvirtHost) async throws -> Void) async throws {
        let previous = state
        state = transient
        do {
            try await body(try server.libvirt)
            // A full re-read, not just the state. libvirt allocates the
            // console port when a domain starts, so a domain that was stopped
            // a moment ago still reports no port until its XML is read again.
            try await refreshDomain()
        } catch {
            state = previous
            throw error
        }
    }

    /// Re-reads the whole domain from the host.
    func refreshDomain() async throws {
        let domain = try await server.libvirt.domain(named: domainName)
        update(from: domain)
    }

    /// Re-reads the domain's state from the host.
    func refreshState() async throws {
        let current = try await server.libvirt.state(ofDomain: domainName)
        let newState = Self.utmState(from: current)
        if newState != state {
            state = newState
        }
    }

    func start(options: UTMVirtualMachineStartOptions) async throws {
        guard !options.contains(.bootDisposibleMode) else {
            throw UTMLibvirtVirtualMachineError.optionUnsupported
        }
        let name = domainName
        try await operation(transitioningTo: .starting) { host in
            try await host.start(domain: name)
        }
    }

    func stop(usingMethod method: UTMVirtualMachineStopMethod) async throws {
        let name = domainName
        try await operation(transitioningTo: .stopping) { host in
            switch method {
            case .request:
                // ACPI shutdown; the guest decides when it is done.
                try await host.shutdown(domain: name)
            case .force, .kill:
                try await host.destroy(domain: name)
            }
        }
        await disconnectConsole()
    }

    func restart() async throws {
        let name = domainName
        try await operation(transitioningTo: .stopping) { host in
            try await host.reset(domain: name)
        }
    }

    func pause() async throws {
        let name = domainName
        try await operation(transitioningTo: .pausing) { host in
            try await host.suspend(domain: name)
        }
    }

    func resume() async throws {
        let name = domainName
        try await operation(transitioningTo: .resuming) { host in
            try await host.resume(domain: name)
        }
    }

    func setAutostart(_ enabled: Bool) async throws {
        try await server.libvirt.setAutostart(enabled, forDomain: domainName)
        let refreshed = try await server.libvirt.domain(named: domainName)
        update(from: refreshed)
    }

    // MARK: - Console

    /// Connects to the domain's console.
    ///
    /// The connection goes through the server, which decides whether to tunnel
    /// it over SSH or reach the host's console port directly.
    func connectConsole() async throws {
        guard domainInfo.hasSupportedConsole else {
            throw UTMLibvirtVirtualMachineError.noConsole
        }
        guard state == .started || state == .paused else {
            throw UTMLibvirtVirtualMachineError.notRunning
        }
        if ioService != nil {
            return
        }
        // The port is assigned at start, so a VM started elsewhere — or
        // whose XML we read while it was stopped — needs a re-read before we
        // know where to connect.
        if domainInfo.preferredGraphics?.port == nil {
            try await refreshDomain()
        }

        let address = try await server.consoleAddress(for: self)
        tunnelPort = address.port

        let options: UTMSpiceIOOptions = []
        let ioService = UTMSpiceIO(host: address.host,
                                   port: address.port,
                                   password: nil,
                                   options: options)
        ioService.logHandler = { (line: String) -> Void in
            guard !line.contains("spice_make_scancode") else {
                return // do not log key presses for privacy reasons
            }
            logger.debug("\(line)")
        }
        let coordinator = ConnectCoordinator()
        ioService.connectDelegate = coordinator
        do {
            try ioService.start()
            try ioService.connect()
        } catch {
            ioService.connectDelegate = nil
            await server.closeConsole(for: self)
            tunnelPort = nil
            throw error
        }

        // This build of the SPICE layer reports failures through the delegate
        // but has no success callback, so completion is observed rather than
        // awaited. The deadline matters: a tunnel to a port nothing is
        // listening on would otherwise hang here indefinitely.
        let deadline = Date().addingTimeInterval(kConsoleConnectTimeout)
        while !ioService.isConnected {
            if let message = coordinator.errorMessage {
                ioService.connectDelegate = nil
                ioService.disconnect()
                await server.closeConsole(for: self)
                tunnelPort = nil
                throw UTMLibvirtVirtualMachineError.consoleFailed(message)
            }
            if Date() >= deadline {
                ioService.connectDelegate = nil
                ioService.disconnect()
                await server.closeConsole(for: self)
                tunnelPort = nil
                throw UTMLibvirtVirtualMachineError.consoleTimedOut
            }
            try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        }

        ioService.connectDelegate = nil
        self.ioService = ioService
    }

    func disconnectConsole() async {
        ioService?.disconnect()
        ioService = nil
        if tunnelPort != nil {
            await server.closeConsole(for: self)
            tunnelPort = nil
        }
    }

    /// Captures the failure message the SPICE layer reports asynchronously.
    ///
    /// The monitor and guest-agent callbacks are QEMU-process concepts that a
    /// libvirt domain never routes to us, so they are ignored.
    private final class ConnectCoordinator: NSObject, QEMUInterfaceConnectDelegate {
        private let lock = NSLock()
        private var _errorMessage: String?

        var errorMessage: String? {
            lock.lock()
            defer { lock.unlock() }
            return _errorMessage
        }

        func qemuInterface(_ qemuInterface: any QEMUInterface, didErrorWithMessage message: String) {
            lock.lock()
            _errorMessage = message
            lock.unlock()
        }

        func qemuInterface(_ qemuInterface: any QEMUInterface, didCreateMonitorPort port: (any QEMUPort)?) {
        }

        func qemuInterface(_ qemuInterface: any QEMUInterface, didCreateGuestAgentPort port: (any QEMUPort)?) {
        }
    }

    func requestInputTablet(_ tablet: Bool) {
        guard let ioService = ioService, !changeCursorRequestInProgress else {
            return
        }
        changeCursorRequestInProgress = true
        ioService.primaryInput?.requestMouseMode(!tablet)
        changeCursorRequestInProgress = false
    }

    /// Opens the domain's serial console.
    ///
    /// Runs `virsh console` on the host over its own SSH channel. The serial
    /// port is a pty on the host, which SPICE does not carry, so this is the
    /// only way to reach a VM that has no graphics.
    func openSerialConsole(onOutput: @escaping @Sendable (Data) -> Void,
                           onClose: @escaping @Sendable () -> Void) async throws -> SSHShellSession {
        guard state == .started || state == .paused else {
            throw UTMLibvirtVirtualMachineError.notRunning
        }
        return try await server.openSerialConsole(forDomain: domainName,
                                                  onOutput: onOutput,
                                                  onClose: onClose)
    }

    // MARK: - Unsupported on a remote domain

    /// Changing media means rewriting the domain's XML on the host, which is
    /// storage management rather than a console operation.
    func eject(_ drive: UTMQemuConfigurationDrive) async throws {
        throw UTMLibvirtVirtualMachineError.notSupportedRemotely
    }

    func changeMedium(_ drive: UTMQemuConfigurationDrive, to url: URL) async throws {
        throw UTMLibvirtVirtualMachineError.notSupportedRemotely
    }

    func stopAccessingPath(_ path: String) async {
        // No local security-scoped resources are held for a remote domain.
    }

    func changeVirtfsSharedDirectory(with bookmark: Data, isSecurityScoped: Bool) async throws {
        throw UTMLibvirtVirtualMachineError.notSupportedRemotely
    }

    // MARK: - Snapshots

    func listSnapshots() async throws -> [UTMVirtualMachineSnapshot] {
        try await server.libvirt.snapshots(ofDomain: domainName).map { snapshot in
            UTMVirtualMachineSnapshot(name: snapshot.name,
                                      creationDate: snapshot.creationDate,
                                      isCurrent: snapshot.isCurrent,
                                      includesMemory: snapshot.includesMemory,
                                      notes: snapshot.notes)
        }
    }

    func saveSnapshot(name: String?) async throws {
        if let error = snapshotUnsupportedError {
            throw error
        }
        let snapshotName = name ?? Self.defaultSnapshotName()
        try await server.libvirt.createSnapshot(ofDomain: domainName, named: snapshotName)
    }

    func restoreSnapshot(name: String?) async throws {
        guard let name else {
            throw UTMLibvirtVirtualMachineError.snapshotNameRequired
        }
        let domain = domainName
        try await operation(transitioningTo: .restoring) { host in
            try await host.revertSnapshot(ofDomain: domain, named: name)
        }
    }

    func deleteSnapshot(name: String?) async throws {
        guard let name else {
            throw UTMLibvirtVirtualMachineError.snapshotNameRequired
        }
        try await server.libvirt.deleteSnapshot(ofDomain: domainName, named: name)
    }

    private static func defaultSnapshotName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    func reloadScreenshotFromFile() throws {
        // No local package to read one from.
    }
}

// MARK: - Errors

enum UTMLibvirtVirtualMachineError: Error {
    case noSnapshotCapableDisk
    case snapshotNameRequired
    case optionUnsupported
    case noConsole
    case notRunning
    case consoleFailed(String)
    case notSupportedRemotely
    case consoleTimedOut
    case volumeNotFoundAfterCreate(String)
    case consolePortUnavailable
}

extension UTMLibvirtVirtualMachineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noSnapshotCapableDisk:
            return NSLocalizedString("This virtual machine has no QCOW2 disk, so it cannot hold snapshots. Raw disks and CD-ROMs do not support them.", comment: "UTMLibvirtVirtualMachine")
        case .snapshotNameRequired:
            return NSLocalizedString("A snapshot name is required.", comment: "UTMLibvirtVirtualMachine")
        case .optionUnsupported:
            return NSLocalizedString("This start option is not supported for remote virtual machines.", comment: "UTMLibvirtVirtualMachine")
        case .noConsole:
            return NSLocalizedString("This virtual machine has no SPICE console configured, so there is no display to show.", comment: "UTMLibvirtVirtualMachine")
        case .notRunning:
            return NSLocalizedString("The virtual machine must be running before its console can be opened.", comment: "UTMLibvirtVirtualMachine")
        case .consoleFailed(let message):
            return String(format: NSLocalizedString("Could not open the console: %@", comment: "UTMLibvirtVirtualMachine"), message)
        case .notSupportedRemotely:
            return NSLocalizedString("This is not supported for virtual machines on a remote host.", comment: "UTMLibvirtVirtualMachine")
        case .consoleTimedOut:
            return NSLocalizedString("Timed out connecting to the console. Check that the VM's SPICE port is reachable on the host.", comment: "UTMLibvirtVirtualMachine")
        case .consolePortUnavailable:
            return NSLocalizedString("The virtual machine has a SPICE console but the host has not assigned it a port yet. Wait a moment and try again.", comment: "UTMLibvirtVirtualMachine")
        case .volumeNotFoundAfterCreate(let name):
            return String(format: NSLocalizedString("Created the disk '%@' but the host did not list it afterwards, so it was not attached.", comment: "UTMLibvirtVirtualMachine"), name)
        }
    }
}
