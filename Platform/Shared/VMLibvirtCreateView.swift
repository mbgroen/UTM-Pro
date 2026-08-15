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

import LibvirtKit
import SwiftUI

/// Creates a virtual machine on a remote libvirt host.
///
/// A single form rather than a multi-step wizard: there are only five
/// decisions, all of them visible at once, and the summary at the end says
/// exactly what will be created before anything is written.
@available(iOS 16, macOS 13, *)
struct VMLibvirtCreateView: View {
    @ObservedObject var server: UTMLibvirtServer

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var memoryGiB: Double = 4
    @State private var vcpuCount: Int = 2
    @State private var poolName: String = ""
    @State private var diskGiB: Double = 32
    @State private var diskFormat: LibvirtVolumeFormat = .qcow2
    @State private var isoPoolName: String = ""
    @State private var isoVolume: LibvirtVolume?
    @State private var isoCandidates: [LibvirtVolume] = []
    @State private var networkOptions: [LibvirtNetworkOption] = []
    @State private var selectedNetwork: LibvirtNetworkOption?
    @State private var startAfterCreate = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var pools: [LibvirtPool] {
        server.pools.filter(\.isActive)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !poolName.isEmpty && diskGiB > 0 && !isWorking
            && !server.virtualMachines.contains { $0.detailsTitleLabel == trimmedName }
    }

    private var volumeFileName: String {
        let safe = trimmedName.replacingOccurrences(of: "/", with: "-")
        return "\(safe).\(diskFormat.rawValue)"
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                hardwareSection
                storageSection
                installerSection
                networkSection
                summarySection
                if let errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 520, minHeight: 560)
            .navigationTitle("New VM on \(server.settings.displayName)")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!isValid)
                }
            }
            .task {
                if poolName.isEmpty {
                    poolName = pools.first?.name ?? ""
                }
                if isoPoolName.isEmpty {
                    // ISOs usually live in their own pool; prefer one whose
                    // name says so rather than making the user hunt.
                    isoPoolName = pools.first { $0.name.lowercased().contains("iso") }?.name
                        ?? pools.first?.name ?? ""
                }
                await loadNetworks()
                await loadISOs()
            }
            .onChange(of: isoPoolName) { _ in
                isoVolume = nil
                Task { await loadISOs() }
            }
        }
    }

    private var identitySection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("debian-web"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("Notes", text: $notes, prompt: Text("Optional"))
        } header: {
            Text("Identity")
        } footer: {
            if !trimmedName.isEmpty,
               server.virtualMachines.contains(where: { $0.detailsTitleLabel == trimmedName }) {
                Text("A VM with this name already exists on this host.")
                    .foregroundColor(.orange)
            } else {
                Text("libvirt identifies the VM by this name, and it must be unique on the host.")
            }
        }
    }

    private var hardwareSection: some View {
        Section {
            LabeledContent("Memory") {
                HStack {
                    TextField("Memory", value: $memoryGiB, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                    Text("GiB")
                }
            }
            Stepper("Processors: \(vcpuCount)", value: $vcpuCount, in: 1...64)
        } header: {
            Text("Hardware")
        } footer: {
            if let hostInfo = server.hostInfo, let cpus = hostInfo.cpuCount {
                Text("The host has \(cpus) processors and \(ByteCountFormatter.string(fromByteCount: Int64(hostInfo.memoryBytes ?? 0), countStyle: .binary)) of memory. Allocating more than it has is allowed but will make guests contend.")
            } else {
                Text("Allocating more than the host has is allowed but will make guests contend.")
            }
        }
    }

    private var storageSection: some View {
        Section {
            Picker("Pool", selection: $poolName) {
                ForEach(pools) { pool in
                    Text(pool.name).tag(pool.name)
                }
            }
            LabeledContent("Disk Size") {
                HStack {
                    TextField("Size", value: $diskGiB, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                    Text("GiB")
                }
            }
            Picker("Format", selection: $diskFormat) {
                ForEach(LibvirtVolumeFormat.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Boot Disk")
        } footer: {
            Text("Created as \(volumeFileName) in the \(poolName.isEmpty ? "selected" : poolName) pool.")
        }
    }

    private var installerSection: some View {
        Section {
            Picker("ISO Pool", selection: $isoPoolName) {
                ForEach(pools) { pool in
                    Text(pool.name).tag(pool.name)
                }
            }
            Picker("Installer", selection: $isoVolume) {
                Text("None").tag(LibvirtVolume?.none)
                ForEach(isoCandidates) { volume in
                    Text(volume.name).tag(LibvirtVolume?.some(volume))
                }
            }
        } header: {
            Text("Installer")
        } footer: {
            if isoCandidates.isEmpty {
                Text("No ISO images found in this pool.")
            } else {
                Text("Attached as a CD and set to boot first, so the VM starts the installer.")
            }
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Network", selection: $selectedNetwork) {
                Text("None").tag(LibvirtNetworkOption?.none)
                ForEach(networkOptions) { option in
                    Text(option.displayName).tag(LibvirtNetworkOption?.some(option))
                }
            }
            Toggle("Start after creating", isOn: $startAfterCreate)
        } header: {
            Text("Network")
        }
    }

    private var summarySection: some View {
        Section {
            // Stated plainly because it differs from what the OMV plugin does,
            // and it is a security improvement worth being explicit about.
            Label("The console will listen on the host's loopback only, and UTM reaches it through the SSH tunnel.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Console")
        }
    }

    private func loadNetworks() async {
        do {
            networkOptions = try await server.libvirt.listNetworkOptions()
            // A bridge is nearly always the right answer on a NAS.
            selectedNetwork = networkOptions.first { $0.kind == .bridge } ?? networkOptions.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadISOs() async {
        guard !isoPoolName.isEmpty else { return }
        do {
            let volumes = try await server.volumes(inPool: isoPoolName)
            isoCandidates = volumes.filter { $0.name.lowercased().hasSuffix(".iso") }
        } catch {
            isoCandidates = []
        }
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.createVirtualMachine(
                    name: trimmedName,
                    notes: notes.isEmpty ? nil : notes,
                    memoryBytes: UInt64(memoryGiB * 1024 * 1024 * 1024),
                    vcpuCount: vcpuCount,
                    poolName: poolName,
                    volumeName: volumeFileName,
                    diskBytes: UInt64(diskGiB * 1024 * 1024 * 1024),
                    diskFormat: diskFormat,
                    isoPath: isoVolume?.path,
                    network: networkSelection,
                    startImmediately: startAfterCreate
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private var networkSelection: LibvirtDomainTemplate.Network {
        guard let selectedNetwork else { return .none }
        switch selectedNetwork.kind {
        case .bridge:
            return .bridge(selectedNetwork.name)
        case .virtualNetwork:
            return .virtualNetwork(selectedNetwork.name)
        }
    }
}
