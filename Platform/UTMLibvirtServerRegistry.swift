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

private let kLibvirtServersKey = "LibvirtServers"

/// The set of configured remote libvirt hosts.
///
/// Kept separate from `UTMData.virtualMachines`, which stays local-only so
/// that deleting, cloning, exporting and every other local-package operation
/// keeps working on exactly the list it always did.
@MainActor
final class UTMLibvirtServerRegistry: ObservableObject {
    @Published private(set) var servers: [UTMLibvirtServer] = []

    /// Republishes child server changes so views observing the registry
    /// update when a server connects or its VM list changes.
    private var observers: [UUID: AnyCancellable] = [:]

    private let defaults: UserDefaults

    /// Background poll, so VMs started elsewhere do not sit stale.
    private var pollingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: kLibvirtServersKey) else { return }
        do {
            let saved = try JSONDecoder().decode([UTMLibvirtServerSettings].self, from: data)
            servers = saved.map { UTMLibvirtServer(settings: $0) }
            servers.forEach(observe)
        } catch {
            logger.error("could not read saved libvirt servers: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(servers.map(\.settings))
            defaults.set(data, forKey: kLibvirtServersKey)
        } catch {
            logger.error("could not save libvirt servers: \(error.localizedDescription)")
        }
    }

    private func observe(_ server: UTMLibvirtServer) {
        observers[server.id] = server.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Managing servers

    func add(_ settings: UTMLibvirtServerSettings) -> UTMLibvirtServer {
        let server = UTMLibvirtServer(settings: settings)
        servers.append(server)
        observe(server)
        save()
        return server
    }

    func update(_ settings: UTMLibvirtServerSettings) {
        guard let server = servers.first(where: { $0.id == settings.id }) else { return }
        server.update(settings: settings)
        save()
    }

    /// Removes a server, its connection and its stored secret.
    func remove(_ server: UTMLibvirtServer) async {
        await server.disconnect()
        UTMLibvirtCredentialStore.delete(for: server.id)
        observers[server.id] = nil
        servers.removeAll { $0.id == server.id }
        save()
    }

    func server(withId id: UUID) -> UTMLibvirtServer? {
        servers.first { $0.id == id }
    }

    /// Persists any host-key pin recorded during a connect.
    func persistSettings() {
        save()
    }

    // MARK: - Connections

    /// Connects every configured server, in parallel.
    func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { @MainActor in
                    await server.connect()
                }
            }
        }
        // Connecting may have pinned a host key on first use.
        save()
    }

    func disconnectAll() async {
        for server in servers {
            await server.disconnect()
        }
    }

    /// Polls connected servers so state changed elsewhere shows up.
    ///
    /// libvirt has an event stream, but reaching it means holding an extra
    /// long-lived channel and parsing an output format meant for humans.
    /// Polling one batched command is far simpler and costs a single round
    /// trip; the interval is long enough not to be chatty and short enough
    /// that a VM started from the OMV web interface appears while the user is
    /// still looking at the window.
    func startPolling(every interval: TimeInterval = 15) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Re-reads domains and pools on every connected server.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers where server.connectionState.isConnected {
                group.addTask { @MainActor in
                    await server.refresh()
                }
            }
        }
    }

    /// Finds the server that owns a VM, for views holding only the VM.
    func server(for vm: VMData) -> UTMLibvirtServer? {
        guard let wrapped = vm.wrapped as? UTMLibvirtVirtualMachine else { return nil }
        return server(withId: wrapped.domainInfo.serverId)
    }
}
