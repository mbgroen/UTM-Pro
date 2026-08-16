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

/// The volumes inside one storage pool.
@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeListView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool

    @State private var volumes: [LibvirtVolume] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// One route, one sheet. Five separate .sheet modifiers on the same view
    /// leaves SwiftUI honouring one of them and fighting over the rest.
    @State private var route: Route?

    enum Route: Identifiable {
        case create
        case resize(LibvirtVolume)
        case clone(LibvirtVolume)
        case convert(LibvirtVolume)
        case delete(LibvirtVolume)

        var id: String {
            switch self {
            case .create: return "create"
            case .resize(let v): return "resize-\(v.id)"
            case .clone(let v): return "clone-\(v.id)"
            case .convert(let v): return "convert-\(v.id)"
            case .delete(let v): return "delete-\(v.id)"
            }
        }
    }

    var body: some View {
        List {
            if isLoading && volumes.isEmpty {
                Label("Loading…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            } else if volumes.isEmpty {
                Label("This pool is empty", systemImage: "tray")
                    .foregroundColor(.secondary)
            }

            ForEach(volumes) { volume in
                VMLibvirtVolumeRow(volume: volume, usedBy: server.domainsUsing(volumePath: volume.path))
                    .contextMenu {
                        Button {
                            route = .resize(volume)
                        } label: {
                            Label("Resize…", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        Button {
                            route = .clone(volume)
                        } label: {
                            Label("Duplicate…", systemImage: "doc.on.doc")
                        }
                        Button {
                            route = .convert(volume)
                        } label: {
                            Label("Convert Format…", systemImage: "arrow.triangle.swap")
                        }
                        Divider()
                        Button(role: .destructive) {
                            route = .delete(volume)
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    }
            }

            if let errorMessage {
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
        .navigationTitle(pool.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    route = .create
                } label: {
                    Label("New Volume", systemImage: "plus")
                }
            }
        }
        .sheet(item: $route) { route in
            switch route {
            case .create:
                VMLibvirtVolumeCreateView(server: server, pool: pool) { await load() }
            case .resize(let volume):
                VMLibvirtVolumeResizeView(server: server, pool: pool, volume: volume) { await load() }
            case .clone(let volume):
                VMLibvirtVolumeCloneView(server: server, pool: pool, volume: volume) { await load() }
            case .convert(let volume):
                VMLibvirtVolumeConvertView(server: server, pool: pool, volume: volume) { await load() }
            case .delete(let volume):
                VMLibvirtVolumeDeleteView(server: server, pool: pool, volume: volume) { await load() }
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            volumes = try await server.volumes(inPool: pool.name)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeRow: View {
    let volume: LibvirtVolume
    let usedBy: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(volume.name)
                Spacer()
                Text(volume.format ?? "?")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                // Virtual and actual size differ a lot for sparse images, and
                // conflating them makes a pool look far fuller than it is.
                Text(format(volume.capacityBytes))
                if volume.isSparse {
                    Text("· \(format(volume.allocationBytes)) on disk")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if !usedBy.isEmpty {
                Label(usedBy.joined(separator: ", "), systemImage: "desktopcomputer")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

// MARK: - Create

@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeCreateView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sizeGiB: Double = 32
    @State private var format: LibvirtVolumeFormat = .qcow2
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VMLibvirtSheet(title: "New Volume in \(pool.name)",
                       confirmTitle: "Create",
                       isConfirmEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
                           && sizeGiB > 0 && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: create) {
            TextField("Name", text: $name, prompt: Text("disk.qcow2"))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            LabeledContent("Size") {
                HStack {
                    TextField("Size", value: $sizeGiB, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                    Text("GiB")
                }
            }
            Picker("Format", selection: $format) {
                ForEach(LibvirtVolumeFormat.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.createVolume(named: name.trimmingCharacters(in: .whitespaces),
                                              inPool: pool.name,
                                              capacityBytes: UInt64(sizeGiB * 1024 * 1024 * 1024),
                                              format: format)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Resize

@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeResizeView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool
    let volume: LibvirtVolume
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sizeGiB: Double
    @State private var confirmShrink = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    init(server: UTMLibvirtServer, pool: LibvirtPool, volume: LibvirtVolume, onFinish: @escaping () async -> Void) {
        self.server = server
        self.pool = pool
        self.volume = volume
        self.onFinish = onFinish
        _sizeGiB = State(initialValue: Double(volume.capacityBytes) / 1_073_741_824)
    }

    private var isShrinking: Bool {
        UInt64(sizeGiB * 1024 * 1024 * 1024) < volume.capacityBytes
    }

    var body: some View {
        VMLibvirtSheet(title: "Resize \(volume.name)",
                       confirmTitle: "Resize",
                       isConfirmEnabled: sizeGiB > 0 && !isWorking && (!isShrinking || confirmShrink),
                       errorMessage: errorMessage,
                       onConfirm: resize) {
            LabeledContent("Current") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(volume.capacityBytes), countStyle: .binary))
            }
            LabeledContent("New Size") {
                HStack {
                    TextField("Size", value: $sizeGiB, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                    Text("GiB")
                }
            }
            if isShrinking {
                // Shrinking throws away whatever lived past the new end. The
                // guest filesystem has to have been shrunk first, and libvirt
                // will not check that for you.
                Toggle(isOn: $confirmShrink) {
                    Text("I have already shrunk the filesystem inside the guest")
                }
                Label("Shrinking discards everything beyond the new size. If the guest filesystem is still larger, it will be corrupted.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resize() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.resizeVolume(named: volume.name,
                                              inPool: pool.name,
                                              toBytes: UInt64(sizeGiB * 1024 * 1024 * 1024),
                                              allowShrink: isShrinking)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Clone

@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeCloneView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool
    let volume: LibvirtVolume
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName: String
    @State private var errorMessage: String?
    @State private var isWorking = false

    init(server: UTMLibvirtServer, pool: LibvirtPool, volume: LibvirtVolume, onFinish: @escaping () async -> Void) {
        self.server = server
        self.pool = pool
        self.volume = volume
        self.onFinish = onFinish
        let base = (volume.name as NSString).deletingPathExtension
        let ext = (volume.name as NSString).pathExtension
        _newName = State(initialValue: ext.isEmpty ? "\(base)-copy" : "\(base)-copy.\(ext)")
    }

    var body: some View {
        VMLibvirtSheet(title: "Duplicate \(volume.name)",
                       confirmTitle: "Duplicate",
                       isConfirmEnabled: !newName.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: clone) {
            TextField("New Name", text: $newName)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Text("Copies the whole image on the host. For a large disk this takes a while, and the pool needs room for both.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clone() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.cloneVolume(named: volume.name,
                                             inPool: pool.name,
                                             toName: newName.trimmingCharacters(in: .whitespaces))
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
struct VMLibvirtVolumeDeleteView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool
    let volume: LibvirtVolume
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var usedBy: [String] {
        server.domainsUsing(volumePath: volume.path)
    }

    var body: some View {
        VMLibvirtSheet(title: "Delete \(volume.name)",
                       confirmTitle: "Delete",
                       isDestructive: true,
                       isConfirmEnabled: typedName == volume.name && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: delete) {
            if !usedBy.isEmpty {
                Label("Attached to \(usedBy.joined(separator: ", ")). Deleting it will break \(usedBy.count == 1 ? "that VM" : "those VMs").",
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This deletes the image from the host. It cannot be undone, and nothing here keeps a copy.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Typing the name is deliberate friction: this is the one action
            // in the app that destroys data with no way back.
            TextField("Type \(volume.name) to confirm", text: $typedName)
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
                try await server.deleteVolume(named: volume.name, inPool: pool.name)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Shared sheet chrome

/// A small form sheet with a title, a confirm button and an error slot.
@available(iOS 16, macOS 13, *)
struct VMLibvirtSheet<Content: View>: View {
    let title: String
    let confirmTitle: String
    var isDestructive: Bool = false
    let isConfirmEnabled: Bool
    let errorMessage: String?
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    content()
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
            .frame(minWidth: 440, minHeight: 240)
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                        onConfirm()
                    }
                    .disabled(!isConfirmEnabled)
                }
            }
        }
    }
}


// MARK: - Convert

/// Converts a volume to another image format.
///
/// Writes a new file rather than changing the original in place, because
/// qemu-img convert cannot do otherwise and because leaving the source intact
/// means a failed conversion costs nothing.
@available(iOS 16, macOS 13, *)
struct VMLibvirtVolumeConvertView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool
    let volume: LibvirtVolume
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: LibvirtVolumeFormat
    @State private var newName: String
    @State private var errorMessage: String?
    @State private var isWorking = false

    init(server: UTMLibvirtServer, pool: LibvirtPool, volume: LibvirtVolume, onFinish: @escaping () async -> Void) {
        self.server = server
        self.pool = pool
        self.volume = volume
        self.onFinish = onFinish
        let target: LibvirtVolumeFormat = volume.format == "qcow2" ? .raw : .qcow2
        _format = State(initialValue: target)
        let base = (volume.name as NSString).deletingPathExtension
        _newName = State(initialValue: "\(base).\(target.rawValue)")
    }

    private var isUsed: Bool {
        !server.domainsUsing(volumePath: volume.path).isEmpty
    }

    var body: some View {
        VMLibvirtSheet(title: "Convert \(volume.name)",
                       confirmTitle: "Convert",
                       isConfirmEnabled: !newName.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: convert) {
            Picker("To Format", selection: $format) {
                ForEach(LibvirtVolumeFormat.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: format) { newValue in
                let base = (newName as NSString).deletingPathExtension
                newName = "\(base).\(newValue.rawValue)"
            }
            TextField("New Name", text: $newName)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Text("Writes a new image and leaves \(volume.name) untouched. The pool needs room for both.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if format == .raw {
                // Worth stating, because it is the usual reason to regret a
                // conversion after the fact.
                Text("Raw images cannot hold snapshots, and any snapshots in the source are not carried over.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isUsed {
                Text("A virtual machine is using the source image. Converting does not switch it over — attach the new image yourself.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func convert() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let directory = (volume.path as NSString).deletingLastPathComponent
                let destination = (directory as NSString)
                    .appendingPathComponent(newName.trimmingCharacters(in: .whitespaces))
                try await server.convertVolume(at: volume.path,
                                               toPath: destination,
                                               format: format,
                                               inPool: pool.name)
                await onFinish()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
