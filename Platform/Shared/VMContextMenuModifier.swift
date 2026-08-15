//
// Copyright © 2020 osy. All rights reserved.
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

struct VMContextMenuModifier: ViewModifier {
    @ObservedObject var vm: VMData
    @EnvironmentObject private var data: UTMData
    @State private var showSharePopup = false
    @State private var showSnapshots = false
    #if WITH_REMOTE_KVM
    @State private var showAddDisk = false
    #endif
    @State private var confirmAction: ConfirmAction?
    @State private var shareItem: VMShareItemModifier.ShareItem?
    
    func body(content: Content) -> some View {
        #if os(macOS)
        if #unavailable(macOS 12) {
            bodyBigSur(content: content)
        } else {
            bodyFull(content: content)
        }
        #else
        return bodyFull(content: content)
        #endif
    }
    
    #if os(macOS)
    @ViewBuilder func bodyBigSur(content: Content) -> some View {
        content.contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([vm.pathUrl])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }
    #endif
    
    /// Full context menu for anything other than Big Sur
    /// - Parameter content: Content
    /// - Returns: View
    @available(macOS 12, *)
    @ViewBuilder func bodyFull(content: Content) -> some View {
        #if WITH_REMOTE_KVM
        if let libvirtVM = vm.wrapped as? UTMLibvirtVirtualMachine {
            remoteMenu(content: content, vm: libvirtVM)
        } else {
            localMenu(content: content)
        }
        #else
        localMenu(content: content)
        #endif
    }

    #if WITH_REMOTE_KVM
    /// Menu for a domain that lives on a remote host.
    ///
    /// Deliberately not the local menu with items disabled: revealing in
    /// Finder, cloning, moving and templating have no meaning for a domain
    /// that has no package on this Mac, and showing them greyed out would
    /// suggest they are merely unavailable right now.
    @available(macOS 12, *)
    @ViewBuilder func remoteMenu(content: Content, vm libvirtVM: UTMLibvirtVirtualMachine) -> some View {
        content.contextMenu {
            switch libvirtVM.state {
            case .started:
                Button {
                    perform { try await libvirtVM.stop(usingMethod: .request) }
                } label: {
                    Label("Shut Down", systemImage: "power")
                }.help("Ask the guest operating system to shut down.")

                Button {
                    perform { try await libvirtVM.pause() }
                } label: {
                    Label("Pause", systemImage: "pause")
                }.help("Freeze the VM. Its memory stays on the host.")

                Button {
                    perform { try await libvirtVM.restart() }
                } label: {
                    Label("Reset", systemImage: "arrow.clockwise")
                }.help("Hard reset, like pressing the reset button.")

                Divider()

                DestructiveButton {
                    perform { try await libvirtVM.stop(usingMethod: .force) }
                } label: {
                    Label("Force Stop", systemImage: "stop")
                }.help("Cut power immediately. The guest gets no chance to flush its disks.")

            case .paused:
                Button {
                    perform { try await libvirtVM.resume() }
                } label: {
                    Label("Resume", systemImage: "playpause")
                }.help("Resume the paused VM.")

                DestructiveButton {
                    perform { try await libvirtVM.stop(usingMethod: .force) }
                } label: {
                    Label("Force Stop", systemImage: "stop")
                }.help("Cut power immediately.")

            default:
                Button {
                    perform { try await libvirtVM.start(options: []) }
                } label: {
                    Label("Run", systemImage: "play")
                }.help("Start the VM on its host.")
            }

            Divider()

            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots…", systemImage: "camera.on.rectangle")
            }
            .help("List, create, restore and delete this VM's snapshots.")

            Button {
                showAddDisk = true
            } label: {
                Label("Add Disk…", systemImage: "internaldrive")
            }
            .disabled(libvirtVM.state != .stopped)
            .help("Create a disk in a storage pool on the host, or attach one that already exists.")

            Divider()

            Button {
                perform { try await libvirtVM.setAutostart(!libvirtVM.domainInfo.isAutostart) }
            } label: {
                Label(libvirtVM.domainInfo.isAutostart ? "Disable Autostart" : "Enable Autostart",
                      systemImage: libvirtVM.domainInfo.isAutostart ? "bolt.slash" : "bolt")
            }.help("Whether the host starts this VM on boot.")

            Button {
                perform { try await libvirtVM.refreshDomain() }
            } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
            }.help("Re-read this VM's state from the host.")
        }
        .sheet(isPresented: $showAddDisk) {
            if #available(iOS 16, macOS 13, *), let server = data.libvirtServers.server(for: vm) {
                VMLibvirtDiskAddView(server: server, vm: libvirtVM)
            }
        }
        .modifier(VMSnapshotsSheetModifier(vm: vm, isPresented: $showSnapshots))
    }

    /// Runs a host operation and surfaces any failure as an alert, rather than
    /// letting it disappear into an unobserved Task.
    private func perform(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                data.alertItem = .message(error.localizedDescription)
            }
        }
    }
    #endif

    @available(macOS 12, *)
    @ViewBuilder func localMenu(content: Content) -> some View {
        content.contextMenu {
            #if os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([vm.pathUrl])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }.help("Reveal where the VM is stored.")
            Divider()
            #endif
            #if !WITH_REMOTE // FIXME: implement remote feature
            Button {
                data.close(vm: vm) // close window
                data.edit(vm: vm)
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }.disabled(vm.hasSuspendState || !vm.isModifyAllowed)
            .help("Modify settings for this VM.")
            #endif
            if vm.hasSuspendState || !vm.isStopped {
                Button {
                    confirmAction = .confirmStopVM(vm: vm)
                } label: {
                    Label("Stop", systemImage: "stop")
                }.help("Stop the running VM.")
            } else if !vm.isModifyAllowed { // paused
                Button {
                    data.run(vm: vm)
                } label: {
                    Label("Resume", systemImage: "playpause")
                }.help("Resume running VM.")
            } else {
                Divider()
                
                Button {
                    data.run(vm: vm)
                } label: {
                    Label("Run", systemImage: "play")
                }.help("Run the VM in the foreground.")
                
                #if os(macOS) && arch(arm64)
                if #available(macOS 13, *), let appleConfig = vm.config as? UTMAppleConfiguration, appleConfig.system.boot.operatingSystem == .macOS {
                    Button {
                        data.run(vm: vm, options: .bootRecovery)
                    } label: {
                        Label("Run Recovery", systemImage: "lifepreserver.fill")
                    }.help("Boot into recovery mode.")
                }
                #endif
                
                if let _ = vm.config as? UTMQemuConfiguration {
                    Button {
                        data.run(vm: vm, options: .bootDisposibleMode)
                    } label: {
                        Label("Run without saving changes", systemImage: "memories")
                    }.help("Run the VM in the foreground, without saving data changes to disk.")
                }
                
                #if os(iOS) || os(visionOS)
                if let qemuConfig = vm.config as? UTMQemuConfiguration {
                    Button {
                        NotificationCenter.default.post(name: NSNotification.InstallGuestTools, object: vm.wrapped!)
                    } label: {
                        Label("Install Windows Guest Tools…", systemImage: "wrench.and.screwdriver")
                    }.help("Download and mount the guest tools for Windows.")
                }
                #endif
                
                Divider()
            }
            if vm.wrapped is UTMQemuVirtualMachine {
                Button {
                    showSnapshots = true
                } label: {
                    Label("Snapshots…", systemImage: "camera.on.rectangle")
                }.help("List, create, restore and delete this VM's snapshots.")
                Divider()
            }
            #if !WITH_REMOTE // FIXME: implement remote feature
            Button {
                shareItem = .utmCopy(vm)
                showSharePopup.toggle()
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }.help("Share a copy of this VM and all its data.")
            #if os(macOS)
            if !vm.isShortcut {
                Button {
                    confirmAction = .confirmMoveVM(vm: vm)
                } label: {
                    Label("Move…", systemImage: "arrow.down.doc")
                }.disabled(!vm.isModifyAllowed)
                .help("Move this VM from internal storage to elsewhere.")
            }
            #endif
            Button {
                confirmAction = .confirmCloneVM(vm: vm)
            } label: {
                Label("Clone…", systemImage: "doc.on.doc")
            }.help("Duplicate this VM along with all its data.")
            Button {
                data.busyWorkAsync {
                    try await data.template(vm: vm)
                }
            } label: {
                Label("New from template…", systemImage: "doc.on.clipboard")
            }.help("Create a new VM with the same configuration as this one but without any data.")
            Divider()
            if vm.isShortcut {
                DestructiveButton {
                    confirmAction = .confirmDeleteVM(vm: vm)
                } label: {
                    Label("Remove", systemImage: "trash")
                }.disabled(!vm.isModifyAllowed)
                .help("Delete this shortcut. The underlying data will not be deleted.")
            } else {
                DestructiveButton {
                    confirmAction = .confirmDeleteVM(vm: vm)
                } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(!vm.isModifyAllowed)
                .help("Delete this VM and all its data.")
            }
            #endif
        }
        .modifier(VMSnapshotsSheetModifier(vm: vm, isPresented: $showSnapshots))
        .modifier(VMShareItemModifier(isPresented: $showSharePopup, shareItem: shareItem))
        .modifier(VMConfirmActionModifier(confirmAction: $confirmAction) { action in
            if case .confirmMoveVM(let vm) = action {
                shareItem = .utmMove(vm)
                showSharePopup.toggle()
            }
        })
    }
}
