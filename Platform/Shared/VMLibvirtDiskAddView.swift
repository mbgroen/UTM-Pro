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

/// Adds a disk to a remote domain.
///
/// A remote VM's storage lives in the host's pools, not on this Mac, so the
/// local file browser is meaningless here. The choice is which pool, and then
/// either a new volume or one that already exists — which is also how someone
/// attaches an installer ISO that is already sitting in a pool.
@available(iOS 16, macOS 13, *)
struct VMLibvirtDiskAddView: View {
    @ObservedObject var server: UTMLibvirtServer
    let vm: UTMLibvirtVirtualMachine

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .create
    @State private var poolName: String = ""
    @State private var volumeName: String = ""
    @State private var sizeGiB: Double = 32
    @State private var format: LibvirtVolumeFormat = .qcow2
    @State private var existingVolumes: [LibvirtVolume] = []
    @State private var selectedVolume: LibvirtVolume?
    @State private var isLoadingVolumes = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case create
        case existing

        var id: String { rawValue }
    }

    private var pools: [LibvirtPool] {
        // Inactive pools cannot serve a volume, so offering them would only
        // produce a failure later.
        server.pools.filter(\.isActive)
    }

    private var selectedPool: LibvirtPool? {
        pools.first { $0.name == poolName }
    }

    private var canSubmit: Bool {
        guard !isWorking, selectedPool != nil else { return false }
        switch mode {
        case .create:
            return !volumeName.trimmingCharacters(in: .whitespaces).isEmpty && sizeGiB > 0
        case .existing:
            return selectedVolume != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                poolSection
                switch mode {
                case .create:
                    createSection
                case .existing:
                    existingSection
                }
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
            .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 500)
            .navigationTitle("Add Disk")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Create" : "Attach") {
                        submit()
                    }
                    .disabled(!canSubmit)
                }
            }
            .task {
                if poolName.isEmpty {
                    poolName = pools.first?.name ?? ""
                }
                await loadVolumes()
            }
            .onChange(of: poolName) { _ in
                selectedVolume = nil
                Task { await loadVolumes() }
            }
        }
    }

    private var poolSection: some View {
        Section {
            Picker("Storage Pool", selection: $poolName) {
                ForEach(pools) { pool in
                    Text(pool.name).tag(pool.name)
                }
            }
            if let pool = selectedPool {
                LabeledContent("Free Space") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(pool.availableBytes),
                                                   countStyle: .binary))
                }
                if let path = pool.targetPath {
                    LabeledContent("Path") {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            Picker("Disk", selection: $mode) {
                Text("Create New").tag(Mode.create)
                Text("Use Existing").tag(Mode.existing)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("On \(server.settings.displayName)")
        } footer: {
            if pools.isEmpty {
                Text("This host has no active storage pool. Start one before adding a disk.")
            }
        }
    }

    private var createSection: some View {
        Section {
            TextField("Name", text: $volumeName, prompt: Text("disk.qcow2"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            LabeledContent("Size") {
                HStack {
                    TextField("Size", value: $sizeGiB, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("GiB")
                }
            }
            Picker("Format", selection: $format) {
                ForEach(LibvirtVolumeFormat.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("New Disk")
        } footer: {
            if let pool = selectedPool, sizeGiB * 1024 * 1024 * 1024 > Double(pool.availableBytes) {
                // qcow2 is sparse, so this over-commits rather than fails. Say
                // so instead of blocking a deliberate choice.
                Text("Larger than the free space in this pool. A QCOW2 disk only consumes what the guest writes, so this will work until the pool actually fills.")
            } else {
                Text("QCOW2 grows as the guest writes and supports snapshots. Raw is slightly faster but takes its full size immediately.")
            }
        }
    }

    private var existingSection: some View {
        Section {
            if isLoadingVolumes {
                Label("Loading…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            } else if existingVolumes.isEmpty {
                Label("No volumes in this pool", systemImage: "tray")
                    .foregroundColor(.secondary)
            } else {
                ForEach(existingVolumes) { volume in
                    Button {
                        selectedVolume = volume
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(volume.name)
                                Text("\(volume.format ?? "?") · \(ByteCountFormatter.string(fromByteCount: Int64(volume.capacityBytes), countStyle: .binary))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedVolume == volume {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Existing Volume")
        } footer: {
            Text("Attaching a volume that another VM is already using will corrupt both. Check before selecting one.")
        }
    }

    private func loadVolumes() async {
        guard !poolName.isEmpty else { return }
        isLoadingVolumes = true
        defer { isLoadingVolumes = false }
        do {
            existingVolumes = try await server.volumes(inPool: poolName)
        } catch {
            errorMessage = error.localizedDescription
            existingVolumes = []
        }
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                switch mode {
                case .create:
                    let bytes = UInt64(sizeGiB * 1024 * 1024 * 1024)
                    try await vm.addDisk(named: volumeName.trimmingCharacters(in: .whitespaces),
                                         inPool: poolName,
                                         capacityBytes: bytes,
                                         format: format)
                case .existing:
                    guard let selectedVolume else { return }
                    let isCDROM = selectedVolume.format == "iso"
                        || selectedVolume.name.lowercased().hasSuffix(".iso")
                    try await vm.attachDisk(at: selectedVolume.path,
                                            format: isCDROM ? .raw : (LibvirtVolumeFormat(rawValue: selectedVolume.format ?? "qcow2") ?? .qcow2),
                                            isCDROM: isCDROM)
                }
                try? await server.refreshPools()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
