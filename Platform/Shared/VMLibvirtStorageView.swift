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

/// Storage pools on a remote host, and the volumes inside them.
@available(iOS 16, macOS 13, *)
struct VMLibvirtStorageView: View {
    @ObservedObject var server: UTMLibvirtServer

    @Environment(\.dismiss) private var dismiss

    @State private var route: Route?

    enum Route: Identifiable {
        case createPool
        case deletePool(LibvirtPool)

        var id: String {
            switch self {
            case .createPool: return "create"
            case .deletePool(let pool): return "delete-\(pool.id)"
            }
        }
    }
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                if server.pools.isEmpty {
                    Section {
                        Label("No storage pools on this host", systemImage: "externaldrive")
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(server.pools) { pool in
                    Section {
                        // Value-based, so the volume list is built when the
                        // user navigates rather than when the row appears.
                        // The closure form constructed every pool's list up
                        // front, and each one immediately fetched its volumes
                        // — one redraw per pool, which is what made the window
                        // flicker on open and close.
                        NavigationLink(value: pool) {
                            VMLibvirtPoolRow(pool: pool)
                        }
                        .disabled(!pool.isActive)

                        poolActions(for: pool)
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
            .navigationDestination(for: LibvirtPool.self) { pool in
                VMLibvirtVolumeListView(server: server, pool: pool)
            }
            .frame(minWidth: 520, minHeight: 460)
            .navigationTitle("Storage on \(server.settings.displayName)")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        route = .createPool
                    } label: {
                        Label("Add Pool", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $route) { route in
                switch route {
                case .createPool:
                    VMLibvirtPoolCreateView(server: server)
                case .deletePool(let pool):
                    VMLibvirtPoolDeleteView(server: server, pool: pool)
                }
            }
            .task {
                await refresh()
            }
        }
    }

    @ViewBuilder private func poolActions(for pool: LibvirtPool) -> some View {
        if pool.isActive {
            Button {
                perform { try await server.rescanPool(named: pool.name) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Re-read this pool's contents. Use after copying files in outside of libvirt.")

            Button {
                perform { try await server.stopPool(named: pool.name) }
            } label: {
                Label("Stop Pool", systemImage: "stop.circle")
            }
            .help("Take the pool offline. Its files are not touched.")
        } else {
            Button {
                perform { try await server.startPool(named: pool.name) }
            } label: {
                Label("Start Pool", systemImage: "play.circle")
            }
        }

        Button {
            perform { try await server.setPoolAutostart(!pool.isAutostart, forPool: pool.name) }
        } label: {
            Label(pool.isAutostart ? "Disable Autostart" : "Enable Autostart",
                  systemImage: pool.isAutostart ? "bolt.slash" : "bolt")
        }
        .help("Whether the host brings this pool online at boot.")

        Button(role: .destructive) {
            route = .deletePool(pool)
        } label: {
            Label("Remove Pool…", systemImage: "trash")
        }
        .help("Removes the pool definition. The files in it are not deleted.")
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await server.refreshPools()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ body: @escaping () async throws -> Void) {
        errorMessage = nil
        Task {
            do {
                try await body()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One pool, with how full it is.
@available(iOS 16, macOS 13, *)
struct VMLibvirtPoolRow: View {
    let pool: LibvirtPool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(pool.name, systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                // State as words, not only a colour: a red bar alone is
                // invisible to a good number of people.
                Text(pool.isActive ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundColor(pool.isActive ? .secondary : .orange)
            }

            if pool.isActive {
                ProgressView(value: pool.usedFraction)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(format(pool.allocationBytes)) of \(format(pool.capacityBytes)) used")
                    Spacer()
                    Text("\(format(pool.availableBytes)) free")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if let path = pool.targetPath {
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            // Says there is something to open. Without it the row reads as a
            // summary and people do not think to click it.
            if pool.isActive {
                Label("Show volumes", systemImage: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else {
                Text("Start the pool to see its volumes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

/// Defines a new directory-backed pool.
@available(iOS 16, macOS 13, *)
struct VMLibvirtPoolCreateView: View {
    @ObservedObject var server: UTMLibvirtServer

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var path: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && path.hasPrefix("/")
            && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Backups"))
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Directory", text: $path, prompt: Text("/srv/dev-disk-by-uuid-…/KVM/Backups"))
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } header: {
                    Text("New Pool on \(server.settings.displayName)")
                } footer: {
                    // The path is on the NAS, so a file picker here would be
                    // browsing the wrong machine entirely.
                    Text("An absolute path on the host. It is created if it does not exist, and the pool is set to start automatically.")
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
            .frame(minWidth: 460, minHeight: 260)
            .navigationTitle("Add Pool")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isWorking = true
                        errorMessage = nil
                        Task {
                            do {
                                try await server.createPool(named: name.trimmingCharacters(in: .whitespaces),
                                                            targetPath: path.trimmingCharacters(in: .whitespaces))
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isWorking = false
                        }
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}


/// Removes a pool's definition.
///
/// Kept separate from deleting a volume, and worded to make the difference
/// unmissable: this forgets where storage is, it does not destroy it. People
/// hesitate over this action far more than the wording warrants, and the ones
/// who do not hesitate are usually confusing it with deleting the contents.
@available(iOS 16, macOS 13, *)
struct VMLibvirtPoolDeleteView: View {
    @ObservedObject var server: UTMLibvirtServer
    let pool: LibvirtPool

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VMLibvirtSheet(title: "Remove \(pool.name)",
                       confirmTitle: "Remove",
                       isDestructive: true,
                       isConfirmEnabled: !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: remove) {
            Text("Removes the pool definition from \(server.settings.displayName). The directory and everything in it stay exactly where they are.")
                .fixedSize(horizontal: false, vertical: true)
            if let path = pool.targetPath {
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pool.isActive {
                Text("The pool is running and will be stopped first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("Virtual machines using disks from this pool keep working — libvirt addresses those by path, not through the pool.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remove() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await server.undefinePool(named: pool.name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
