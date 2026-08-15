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

/// One sidebar section per configured libvirt host.
@available(iOS 16, macOS 13, *)
struct VMLibvirtServerSections: View {
    @ObservedObject var registry: UTMLibvirtServerRegistry
    @Binding var editingServer: UTMLibvirtServerSettings?

    var body: some View {
        ForEach(registry.servers) { server in
            VMLibvirtServerSection(server: server,
                                   registry: registry,
                                   editingServer: $editingServer)
        }
    }
}

@available(iOS 16, macOS 13, *)
struct VMLibvirtServerSection: View {
    @ObservedObject var server: UTMLibvirtServer
    @ObservedObject var registry: UTMLibvirtServerRegistry
    @Binding var editingServer: UTMLibvirtServerSettings?

    @EnvironmentObject private var data: UTMData
    @State private var isExpanded: Bool = true
    @State private var confirmRemove: Bool = false

    var body: some View {
        Section(header: header) {
            switch server.connectionState {
            case .connected:
                if server.virtualMachines.isEmpty {
                    Label("No virtual machines", systemImage: "tray")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(server.virtualMachines) { vm in
                        VMCardView(vm: vm)
                            .modifier(VMContextMenuModifier(vm: vm))
                            .tag(vm)
                    }
                }
            case .connecting:
                Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            case .disconnected:
                Button {
                    Task { await connect() }
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal")
                }
            case .failed(let message):
                statusRow(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                Button {
                    Task { await connect() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            case .untrustedHostKey(let fingerprint, let isChange):
                hostKeyPrompt(fingerprint: fingerprint, isChange: isChange)
            }
        }
        .confirmationDialog("Remove this server?",
                            isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await registry.remove(server) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The virtual machines on \(server.settings.displayName) are not affected. Only the saved connection and its credential are removed from this Mac.")
        }
    }

    private var header: some View {
        HStack {
            Label(server.settings.displayName, systemImage: "externaldrive.connected.to.line.below")
            Spacer()
            statusIndicator
            Menu {
                if server.connectionState.isConnected {
                    Button {
                        Task { await server.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await server.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "bolt.horizontal.circle")
                    }
                } else {
                    Button {
                        Task { await connect() }
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                }
                Divider()
                Button {
                    editingServer = server.settings
                } label: {
                    Label("Edit Server…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove Server", systemImage: "trash")
                }
            } label: {
                Label("Server Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder private var statusIndicator: some View {
        switch server.connectionState {
        case .connected:
            Text("\(server.virtualMachines.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        case .connecting:
            Spinner(size: .regular)
        case .failed, .untrustedHostKey:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .disconnected:
            EmptyView()
        }
    }

    private func statusRow(_ message: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundColor(tint)
        }
    }

    /// Shown when the host key is unknown or has changed.
    ///
    /// A changed key is treated as alarming rather than routine: it means
    /// either the host was rebuilt or something is impersonating it, and the
    /// user is the only one who can tell those apart.
    @ViewBuilder private func hostKeyPrompt(fingerprint: String, isChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(isChange ? "Host key changed" : "Unknown host key")
                    .font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundColor(isChange ? .red : .orange)
            }
            if isChange {
                Text("This server is presenting a different key than the one trusted before. If you did not rebuild or reinstall it, do not continue.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(fingerprint)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Compare this against `ssh-keygen -lf` on the server before trusting it.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(isChange ? "Trust New Key" : "Trust and Connect") {
                Task {
                    await server.connect(trustingHostKey: true)
                    registry.persistSettings()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func connect() async {
        await server.connect()
        registry.persistSettings()
    }
}
