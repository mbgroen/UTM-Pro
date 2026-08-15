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

/// Hosts the add/edit server sheet and the toolbar entry point for it.
@available(iOS 16, macOS 13, *)
struct VMLibvirtServerSheetModifier: ViewModifier {
    @Binding var editingServer: UTMLibvirtServerSettings?

    @EnvironmentObject private var data: UTMData

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        editingServer = UTMLibvirtServerSettings()
                    } label: {
                        Label("Add Server", systemImage: "externaldrive.badge.plus")
                    }
                    .help("Add a remote KVM server")
                }
            }
            .sheet(item: $editingServer) { settings in
                UTMLibvirtServerEditSheet(settings: settings)
            }
            .task {
                // Reconnect saved servers on launch so the sidebar is
                // populated without the user having to ask.
                await data.libvirtServers.connectAll()
                data.libvirtServers.startPolling()
            }
    }
}

/// Wraps the form so the sheet owns a mutable copy: edits are discarded unless
/// the user saves.
@available(iOS 16, macOS 13, *)
private struct UTMLibvirtServerEditSheet: View {
    @State private var settings: UTMLibvirtServerSettings

    @EnvironmentObject private var data: UTMData

    init(settings: UTMLibvirtServerSettings) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            UTMLibvirtServerEditView(settings: $settings) { saved, secret in
                save(saved, secret: secret)
            }
            .navigationTitle(isExisting ? "Edit Server" : "Add Server")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var isExisting: Bool {
        data.libvirtServers.server(withId: settings.id) != nil
    }

    private func save(_ saved: UTMLibvirtServerSettings, secret: String?) {
        if let secret {
            try? UTMLibvirtCredentialStore.save(secret: secret, for: saved.id)
        }
        if data.libvirtServers.server(withId: saved.id) != nil {
            data.libvirtServers.update(saved)
        } else {
            _ = data.libvirtServers.add(saved)
        }
        if let server = data.libvirtServers.server(withId: saved.id) {
            Task {
                await server.connect()
                data.libvirtServers.persistSettings()
            }
        }
    }
}

@available(iOS 16, macOS 13, *)
extension UTMLibvirtServerSettings {
    /// `sheet(item:)` needs Identifiable, which `id` already provides.
    var sheetIdentity: UUID { id }
}

/// Applies the server sheet only where the required SwiftUI features exist.
///
/// UTM still supports systems older than the APIs this feature uses, so the
/// availability check lives here rather than at every call site.
struct VMLibvirtServerSheetCompatModifier: ViewModifier {
    @Binding var editingServer: UTMLibvirtServerSettings?

    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content.modifier(VMLibvirtServerSheetModifier(editingServer: $editingServer))
        } else {
            content
        }
    }
}
