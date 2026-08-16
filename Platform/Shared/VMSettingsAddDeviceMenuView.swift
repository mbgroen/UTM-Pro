//
// Copyright © 2022 osy. All rights reserved.
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

struct VMSettingsAddDeviceMenuView: View {
    @ObservedObject var config: UTMQemuConfiguration
    @Binding var isCreateDriveShown: Bool
    @Binding var isImportDriveShown: Bool

    #if WITH_REMOTE_KVM
    /// Set when this VM runs on another machine, in which case the menu adds
    /// hardware to the domain there rather than to a local configuration.
    var remoteVM: UTMLibvirtVirtualMachine?
    @EnvironmentObject private var data: UTMData
    @State private var showRemoteDisk = false
    @State private var showRemoteNetwork = false
    #endif
    
    init(config: UTMQemuConfiguration,
         isCreateDriveShown: Binding<Bool>? = nil,
         isImportDriveShown: Binding<Bool>? = nil,
         remoteVM: AnyObject? = nil) {
        self.config = config
        #if WITH_REMOTE_KVM
        self.remoteVM = remoteVM as? UTMLibvirtVirtualMachine
        #endif
        if let isCreateDriveShown = isCreateDriveShown {
            _isCreateDriveShown = isCreateDriveShown
        } else {
            _isCreateDriveShown = .constant(false)
        }
        if let isImportDriveShown = isImportDriveShown {
            _isImportDriveShown = isImportDriveShown
        } else {
            _isImportDriveShown = .constant(false)
        }
    }
    
    private var isAddDisplayEnabled: Bool {
        if [.sparc, .sparc64, .m68k].contains(config.system.architecture) {
            return config.displays.count < 1
        } else {
            return !config.system.architecture.displayDeviceType.allRawValues.isEmpty
        }
    }
    
    var body: some View {
        #if WITH_REMOTE_KVM
        if #available(iOS 16, macOS 13, *), let remoteVM {
            remoteMenu(for: remoteVM)
        } else {
            localMenu
        }
        #else
        localMenu
        #endif
    }

    #if WITH_REMOTE_KVM
    /// Only what libvirt can actually add to a defined domain.
    ///
    /// Displays, serial ports and sound cards would mean rewriting the
    /// domain's XML, so they are left out rather than offered and ignored.
    @available(iOS 16, macOS 13, *)
    @ViewBuilder private func remoteMenu(for vm: UTMLibvirtVirtualMachine) -> some View {
        Menu {
            Button {
                showRemoteDisk = true
            } label: {
                Label("Drive", systemImage: "internaldrive")
            }
            Button {
                showRemoteNetwork = true
            } label: {
                Label("Network", systemImage: "network")
            }
        } label: {
            Label("New…", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .disabled(vm.state != .stopped)
        .help(vm.state == .stopped
              ? "Add hardware to this VM on its host."
              : "Stop the VM to change its hardware.")
        .sheet(isPresented: $showRemoteDisk) {
            if let server = data.libvirtServers.server(withId: vm.domainInfo.serverId) {
                VMLibvirtDiskAddView(server: server, vm: vm)
            }
        }
        .sheet(isPresented: $showRemoteNetwork) {
            if let server = data.libvirtServers.server(withId: vm.domainInfo.serverId) {
                VMLibvirtNetworkAddView(server: server, vm: vm)
            }
        }
    }
    #endif

    @ViewBuilder private var localMenu: some View {
        Menu {
            Button {
                let newDisplay = UTMQemuConfigurationDisplay(forArchitecture: config.system.architecture, target: config.system.target)
                config.displays.append(newDisplay!)
            } label: {
                Label("Display", systemImage: "rectangle.on.rectangle")
            }.disabled(!isAddDisplayEnabled)
            Button {
                let newSerial = UTMQemuConfigurationSerial(forArchitecture: config.system.architecture, target: config.system.target)
                config.serials.append(newSerial!)
            } label: {
                Label("Serial", systemImage: "rectangle.connected.to.line.below")
            }
            Button {
                let newNetwork = UTMQemuConfigurationNetwork(forArchitecture: config.system.architecture, target: config.system.target)
                config.networks.append(newNetwork!)
            } label: {
                Label("Network", systemImage: "network")
            }.disabled(config.system.architecture.networkDeviceType.allRawValues.isEmpty)
            Button {
                let newSound = UTMQemuConfigurationSound(forArchitecture: config.system.architecture, target: config.system.target)
                config.sound.append(newSound!)
            } label: {
                Label("Sound", systemImage: "speaker.wave.2")
            }.disabled(config.system.architecture.soundDeviceType.allRawValues.isEmpty)
            #if os(iOS) || os(visionOS)
            Divider()
            Button {
                isImportDriveShown.toggle()
            } label: {
                Label("Import Drive…", systemImage: "externaldrive")
            }
            Button {
                isCreateDriveShown.toggle()
            } label: {
                Label("New Drive…", systemImage: "externaldrive.badge.plus")
            }
            #endif
        } label: {
            if #available(iOS 15, macOS 11, *) {
                Label("New…", systemImage: "plus")
            } else {
                Label("New…", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
        }.help("Add a new device.")
        .menuStyle(.borderlessButton)
    }
}

struct VMSettingsAddDeviceMenuView_Previews: PreviewProvider {
    @StateObject static private var config = UTMQemuConfiguration()
    
    static var previews: some View {
        VMSettingsAddDeviceMenuView(config: config)
    }
}
