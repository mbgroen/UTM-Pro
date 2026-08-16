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

/// What you can do to a remote VM, on the detail pane.
///
/// These lived only in the right-click menu, which is not where people look
/// for "add a disk". A local VM shows its removable drives in this spot; a
/// remote one shows the actions that apply to it instead.
@available(iOS 16, macOS 13, *)
struct VMLibvirtActionsView: View {
    @ObservedObject var vm: VMData
    let libvirtVM: UTMLibvirtVirtualMachine

    @EnvironmentObject private var data: UTMData

    @State private var showSnapshots = false

    private var server: UTMLibvirtServer? {
        data.libvirtServers.server(for: vm)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots…", systemImage: "camera.on.rectangle")
            }
            .help("List, create, restore and delete snapshots.")

            #if os(macOS)
            Button {
                data.openRemoteSerialConsole(vm: vm, libvirtVM: libvirtVM)
            } label: {
                Label("Serial Console…", systemImage: "terminal")
            }
            .disabled(libvirtVM.state != .started)
            .help("Attach to the VM's serial console over SSH.")
            #endif

            Spacer()
        }
        .buttonStyle(.bordered)
        .modifier(VMSnapshotsSheetModifier(vm: vm, isPresented: $showSnapshots))
    }
}
