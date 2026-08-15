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

/// A virtual machine running on a remote libvirt host.
///
/// Conforms to `UTMVirtualMachine` so it can use the same list, detail and
/// session views as local VMs. The parts of that protocol that assume a local
/// `.utm` package are not implemented, following the precedent set by
/// `UTMRemoteSpiceVirtualMachine`.
@MainActor
final class UTMLibvirtVirtualMachine: UTMVirtualMachine {
    struct Capabilities: UTMVirtualMachineCapabilities {
        /// libvirt's `destroy` is a process kill in all but name.
        var supportsProcessKill: Bool { true }

        var supportsSnapshots: Bool { true }

        /// Screenshots would need a console connection; the list shows state
        /// instead.
        var supportsScreenshots: Bool { false }

        var supportsDisposibleMode: Bool { false }

        var supportsRecoveryMode: Bool { false }

        var supportsRemoteSession: Bool { false }
    }

    static let capabilities = Capabilities()

    /// The host this domain lives on.
    private let server: UTMLibvirtServer

    private(set) var config: UTMLibvirtConfiguration

    private(set) var registryEntry: UTMRegistryEntry

    /// libvirt addresses domains by name, so this is carried separately from
    /// the display name.
    var domainName: String { config.domainName }

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
    var snapshotUnsupportedError: Error? {
        config.supportsInternalSnapshots
            ? nil
            : UTMLibvirtVirtualMachineError.noSnapshotCapableDisk
    }

    var isHeadless: Bool {
        config.graphics.isEmpty
    }

    init(server: UTMLibvirtServer, domain: LibvirtDomain) {
        self.server = server
        self.config = UTMLibvirtConfiguration(domain: domain, serverId: server.id)
        self.pathUrl = Self.syntheticPath(serverId: server.id, domainName: domain.name)
        self.registryEntry = UTMRegistry.shared.entry(uuid: domain.uuid,
                                                      name: domain.name,
                                                      path: self.pathUrl.path)
        self.state = Self.utmState(from: domain.state)
    }

    /// Not applicable: remote domains are never instantiated from a package.
    init(packageUrl: URL, configuration: UTMLibvirtConfiguration, isShortcut: Bool) throws {
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
        config.apply(domain: domain)
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

    func save() async throws {
        // There is no local package to write.
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
            try await body(server.libvirt)
            try await refreshState()
        } catch {
            state = previous
            throw error
        }
    }

    /// Re-reads the domain's state from the host.
    func refreshState() async throws {
        let current = try await server.libvirt.state(ofDomain: domainName)
        state = Self.utmState(from: current)
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

    // MARK: - Snapshots

    /// Lists the domain's snapshots.
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

    // MARK: - Screenshots

    func takeScreenshot() async -> Bool {
        false
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
            return NSLocalizedString("This virtual machine has no graphical console configured.", comment: "UTMLibvirtVirtualMachine")
        }
    }
}
