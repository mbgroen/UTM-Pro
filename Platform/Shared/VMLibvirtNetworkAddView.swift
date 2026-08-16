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

/// Attaches a network interface to a remote domain.
///
/// The choice is which of the host's networks to join, which is not something
/// the local hardware menu can express — it offers emulated adapters that mean
/// nothing to a guest running on another machine.
@available(iOS 16, macOS 13, *)
struct VMLibvirtNetworkAddView: View {
    @ObservedObject var server: UTMLibvirtServer
    let vm: UTMLibvirtVirtualMachine

    @Environment(\.dismiss) private var dismiss

    @State private var options: [LibvirtNetworkOption] = []
    @State private var selected: LibvirtNetworkOption?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VMLibvirtSheet(title: "Add Network Interface",
                       confirmTitle: "Attach",
                       isConfirmEnabled: selected != nil && !isWorking,
                       errorMessage: errorMessage,
                       onConfirm: attach) {
            if isLoading {
                Label("Loading…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            } else {
                Picker("Network", selection: $selected) {
                    Text("Select…").tag(LibvirtNetworkOption?.none)
                    ForEach(options) { option in
                        Text(option.displayName).tag(LibvirtNetworkOption?.some(option))
                    }
                }
            }
            Text("A new interface gets its own MAC address, so the guest sees it as a second card.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if vm.state != .stopped {
                // The interface is attached persistently either way; what a
                // running guest does with it is up to the guest.
                Text("The interface is added now and kept across reboots. A running guest may not see it until it restarts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            do {
                options = try await server.libvirt.listNetworkOptions()
                selected = options.first { $0.kind == .bridge && !$0.isContainerBridge }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func attach() {
        guard let selected else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await vm.addNetworkInterface(source: selected.name,
                                                 isVirtualNetwork: selected.kind == .virtualNetwork)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
