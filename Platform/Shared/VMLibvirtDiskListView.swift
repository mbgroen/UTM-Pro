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

/// The disks attached to a remote VM, with add and detach.
@available(iOS 16, macOS 13, *)
struct VMLibvirtDiskListView: View {
    @ObservedObject var server: UTMLibvirtServer
    let vm: UTMLibvirtVirtualMachine

    @Environment(\.dismiss) private var dismiss

    @State private var showAdd = false
    @State private var detaching: DiskEntry?
    @State private var errorMessage: String?

    /// A disk as shown here: the guest device plus where it lives on the host.
    struct DiskEntry: Identifiable, Hashable {
        let target: String
        let path: String?
        let format: String?
        let isCDROM: Bool

        var id: String { target }
    }

    private var disks: [DiskEntry] {
        vm.config.drives.map { drive in
            DiskEntry(target: drive.id,
                      path: vm.domainInfo.diskPaths[drive.id],
                      format: drive.isRawImage ? "raw" : "qcow2",
                      isCDROM: drive.imageType == .cd)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if disks.isEmpty {
                        Label("No disks attached", systemImage: "internaldrive")
                            .foregroundColor(.secondary)
                    }
                    ForEach(disks) { disk in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label(disk.target,
                                      systemImage: disk.isCDROM ? "opticaldiscdrive" : "internaldrive")
                                Spacer()
                                Text(disk.format ?? "?")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let path = disk.path {
                                Text(path)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button(role: .destructive) {
                                detaching = disk
                            } label: {
                                Label("Detach…", systemImage: "eject")
                            }
                        }
                    }
                } header: {
                    Text("Disks")
                } footer: {
                    if vm.state != .stopped {
                        Text("Stop the virtual machine to change its disks.")
                    } else {
                        Text("Detaching leaves the image on the host. Delete it from Storage if you want the space back.")
                    }
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
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle("\(vm.domainName) Disks")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Disk", systemImage: "plus")
                    }
                    .disabled(vm.state != .stopped)
                }
            }
            .sheet(isPresented: $showAdd) {
                VMLibvirtDiskAddView(server: server, vm: vm)
            }
            .sheet(item: $detaching) { disk in
                VMLibvirtSheet(title: "Detach \(disk.target)",
                               confirmTitle: "Detach",
                               isDestructive: true,
                               isConfirmEnabled: true,
                               errorMessage: nil) {
                    detach(disk)
                } content: {
                    // Detaching is not deletion, and saying so avoids people
                    // hesitating over a reversible action — or assuming the
                    // space came back when it did not.
                    Text("Removes \(disk.target) from this virtual machine. The image stays on the host and can be attached again.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let path = disk.path {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func detach(_ disk: DiskEntry) {
        errorMessage = nil
        Task {
            do {
                try await vm.removeDisk(targetDevice: disk.target)
                detaching = nil
            } catch {
                errorMessage = error.localizedDescription
                detaching = nil
            }
        }
    }
}

/// Deletes a remote VM.
@available(iOS 16, macOS 13, *)
struct VMLibvirtDeleteView: View {
    @ObservedObject var server: UTMLibvirtServer
    let vm: UTMLibvirtVirtualMachine

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var removeStorage = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var diskPaths: [String] {
        vm.domainInfo.diskPaths.values.sorted()
    }

    var body: some View {
        VMLibvirtSheet(title: "Delete \(vm.domainName)",
                       confirmTitle: "Delete",
                       isDestructive: true,
                       isConfirmEnabled: typedName == vm.domainName && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: delete) {
            if vm.state != .stopped {
                Label("This VM is running and will be powered off first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Removes the virtual machine from \(server.settings.displayName).")
                .fixedSize(horizontal: false, vertical: true)

            // The distinction that matters: without this, the disks survive
            // and the VM can be recreated around them. With it, nothing does.
            Toggle(isOn: $removeStorage) {
                Text("Also delete its disks")
            }
            if removeStorage {
                Label("The following images will be destroyed with no way back:",
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(diskPaths, id: \.self) { path in
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text("Its disks stay on the host, so the VM can be built again around them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Type \(vm.domainName) to confirm", text: $typedName)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }

    private func delete() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.deleteVirtualMachine(vm, removeStorage: removeStorage)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
