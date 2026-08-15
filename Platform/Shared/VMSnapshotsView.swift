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

import SwiftUI

/// Snapshots for any VM, local or remote.
///
/// Both backends store internal snapshots in a QCOW2 image and expose the same
/// four operations, so this is deliberately backend-agnostic — the only thing
/// it needs from a VM is the protocol.
@available(iOS 16, macOS 13, *)
struct VMSnapshotsView: View {
    @ObservedObject var vm: VMData

    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [UTMVirtualMachineSnapshot] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreate = false
    @State private var reverting: UTMVirtualMachineSnapshot?
    @State private var deleting: UTMVirtualMachineSnapshot?

    private var wrapped: (any UTMVirtualMachine)? {
        vm.wrapped
    }

    /// Reported by the backend before anything is attempted, so an
    /// unsupported VM explains itself rather than failing on first use.
    private var unsupportedReason: String? {
        wrapped?.snapshotUnsupportedError?.localizedDescription
    }

    var body: some View {
        NavigationStack {
            List {
                if let unsupportedReason {
                    Section {
                        Label {
                            Text(unsupportedReason)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section {
                    if isLoading && snapshots.isEmpty {
                        Label("Loading…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundColor(.secondary)
                    } else if snapshots.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("No snapshots", systemImage: "camera.on.rectangle")
                                .foregroundColor(.secondary)
                            Text("A snapshot records the disk as it is now, so you can come back to this point after a change goes wrong.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(snapshots) { snapshot in
                            VMSnapshotRow(snapshot: snapshot)
                                .contextMenu {
                                    Button {
                                        reverting = snapshot
                                    } label: {
                                        Label("Restore…", systemImage: "clock.arrow.circlepath")
                                    }
                                    Button(role: .destructive) {
                                        deleting = snapshot
                                    } label: {
                                        Label("Delete…", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Snapshots")
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
            .frame(minWidth: 480, minHeight: 400)
            .navigationTitle("\(vm.detailsTitleLabel) Snapshots")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Snapshot", systemImage: "plus")
                    }
                    .disabled(unsupportedReason != nil)
                }
            }
            .sheet(isPresented: $showCreate) {
                VMSnapshotCreateView(vm: vm) { await load() }
            }
            .sheet(item: $reverting) { snapshot in
                VMSnapshotRestoreView(vm: vm, snapshot: snapshot) { await load() }
            }
            .sheet(item: $deleting) { snapshot in
                VMSnapshotDeleteView(vm: vm, snapshot: snapshot) { await load() }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let wrapped else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots = try await wrapped.listSnapshots()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@available(iOS 16, macOS 13, *)
struct VMSnapshotRow: View {
    let snapshot: UTMVirtualMachineSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(snapshot.name)
                if snapshot.isCurrent {
                    Text("Current")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
                Spacer()
                if let date = snapshot.creationDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Whether RAM was captured decides what restoring actually does,
            // so it belongs on the row rather than buried in a dialog.
            Label(snapshot.includesMemory ? "Includes memory — restoring resumes where it left off"
                                          : "Disk only — restoring boots from this point",
                  systemImage: snapshot.includesMemory ? "memorychip" : "internaldrive")
                .font(.caption)
                .foregroundColor(.secondary)
            if let notes = snapshot.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Create

@available(iOS 16, macOS 13, *)
struct VMSnapshotCreateView: View {
    @ObservedObject var vm: VMData
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var willIncludeMemory: Bool {
        vm.state == .started || vm.state == .paused
    }

    var body: some View {
        VMLibvirtSheet(title: "New Snapshot",
                       confirmTitle: "Create",
                       isConfirmEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: create) {
            TextField("Name", text: $name, prompt: Text("before-upgrade"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Label(willIncludeMemory
                    ? "The VM is running, so this captures memory as well as disk. Restoring it will resume execution."
                    : "The VM is stopped, so this captures the disk only. Restoring it will boot from this point.",
                  systemImage: willIncludeMemory ? "memorychip" : "internaldrive")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await vm.wrapped?.saveSnapshot(name: name.trimmingCharacters(in: .whitespaces))
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Restore

@available(iOS 16, macOS 13, *)
struct VMSnapshotRestoreView: View {
    @ObservedObject var vm: VMData
    let snapshot: UTMVirtualMachineSnapshot
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VMLibvirtSheet(title: "Restore \(snapshot.name)",
                       confirmTitle: "Restore",
                       isDestructive: true,
                       isConfirmEnabled: !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: restore) {
            // Restoring is destructive in a way people underestimate: it is
            // not "load a copy", it throws away the present state.
            Label("Everything written since this snapshot will be lost.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let date = snapshot.creationDate {
                LabeledContent("Taken") {
                    Text(date, format: .dateTime)
                }
            }
            Text(snapshot.includesMemory
                    ? "This snapshot includes memory, so the VM will resume exactly where it was."
                    : "This snapshot is disk only, so the VM will boot from this point.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restore() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await vm.wrapped?.restoreSnapshot(name: snapshot.name)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Delete

@available(iOS 16, macOS 13, *)
struct VMSnapshotDeleteView: View {
    @ObservedObject var vm: VMData
    let snapshot: UTMVirtualMachineSnapshot
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VMLibvirtSheet(title: "Delete \(snapshot.name)",
                       confirmTitle: "Delete",
                       isDestructive: true,
                       isConfirmEnabled: !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: delete) {
            // Deliberately lighter than the volume-delete dialog: this removes
            // a restore point, it does not touch the VM's current disk.
            Text("Removes this restore point. The virtual machine and its current disk are not affected.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func delete() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await vm.wrapped?.deleteSnapshot(name: snapshot.name)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Presents the snapshot sheet only where the required SwiftUI exists.
struct VMSnapshotsSheetModifier: ViewModifier {
    @ObservedObject var vm: VMData
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content.sheet(isPresented: $isPresented) {
                VMSnapshotsView(vm: vm)
            }
        } else {
            content
        }
    }
}
