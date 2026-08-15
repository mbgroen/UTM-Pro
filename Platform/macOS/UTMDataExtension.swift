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

import Foundation
import Carbon.HIToolbox

@available(macOS 11, *)
extension UTMData {
    func run(vm: VMData, options: UTMVirtualMachineStartOptions = [], startImmediately: Bool = true) {
        #if WITH_REMOTE_KVM
        // A remote domain runs on its host, not here. There is no local window
        // to open and no local architecture requirement to satisfy, so this
        // must be handled before the backend checks below — they would
        // otherwise reject an x86_64 guest simply because this Mac is arm64.
        if let libvirtVM = vm.wrapped as? UTMLibvirtVirtualMachine {
            runRemote(vm: vm, libvirtVM: libvirtVM, options: options, startImmediately: startImmediately)
            return
        }
        #endif
        var window: Any? = vmWindows[vm]
        if window == nil {
            let close = {
                self.vmWindows.removeValue(forKey: vm)
                window = nil
            }
            if let avm = vm.wrapped as? UTMAppleVirtualMachine {
                if avm.config.system.architecture == UTMAppleConfigurationSystem.currentArchitecture {
                    let primarySerialIndex = avm.config.serials.firstIndex { $0.mode == .builtin }
                    if let primarySerialIndex = primarySerialIndex {
                        window = VMDisplayAppleTerminalWindowController(primaryForIndex: primarySerialIndex, vm: avm, onClose: close)
                    }
                    if #available(macOS 12, *), !avm.config.displays.isEmpty {
                        window = VMDisplayAppleDisplayWindowController(vm: avm, onClose: close)
                    } else if avm.config.displays.isEmpty && window == nil {
                        window = VMHeadlessSessionState(for: avm, onStop: close)
                    }
                }
            }
            if let qvm = vm.wrapped as? UTMQemuVirtualMachine {
                if !qvm.config.displays.isEmpty {
                    window = VMDisplayQemuMetalWindowController(vm: qvm, onClose: close)
                } else if !qvm.config.serials.filter({ $0.mode == .builtin }).isEmpty {
                    window = VMDisplayQemuTerminalWindowController(vm: qvm, onClose: close)
                } else {
                    window = VMHeadlessSessionState(for: qvm, onStop: close)
                }
            }
            if window == nil {
                DispatchQueue.main.async {
                    self.alertItem = .message(NSLocalizedString("This virtual machine cannot be run on this machine.", comment: "UTMDataExtension"))
                }
            }
        }
        if let unwrappedWindow = window as? VMDisplayWindowController {
            vmWindows[vm] = unwrappedWindow
            vm.wrapped!.delegate = unwrappedWindow
            unwrappedWindow.showWindow(nil)
            unwrappedWindow.window!.makeMain()
            if startImmediately {
                unwrappedWindow.requestAutoStart(options: options)
            }
        } else if let unwrappedWindow = window as? VMHeadlessSessionState {
            vmWindows[vm] = unwrappedWindow
            if startImmediately {
                if vm.wrapped!.state == .paused {
                    vm.wrapped!.requestVmResume()
                } else if vm.wrapped!.state == .stopped {
                    vm.wrapped!.requestVmStart(options: options)
                }
            }
        } else {
            logger.critical("Failed to create window controller.")
        }
    }
    
    #if WITH_REMOTE_KVM
    /// Starts a remote domain and, if it has a console, shows it.
    ///
    /// The domain executes on its host, so nothing here launches a process.
    /// The window is a SPICE client pointed at the host's console — reached
    /// through the SSH tunnel when the server is configured to use one.
    func runRemote(vm: VMData,
                   libvirtVM: UTMLibvirtVirtualMachine,
                   options: UTMVirtualMachineStartOptions,
                   startImmediately: Bool) {
        Task {
            do {
                if startImmediately {
                    if libvirtVM.state == .paused {
                        try await libvirtVM.resume()
                    } else if libvirtVM.state == .stopped {
                        try await libvirtVM.start(options: options)
                    }
                }

                guard !libvirtVM.isHeadless else {
                    // No graphics at all, so the serial console is the only
                    // view there is — and the one a server VM actually wants.
                    self.openRemoteSerialConsole(vm: vm, libvirtVM: libvirtVM)
                    return
                }

                if let existing = vmWindows[vm] as? VMDisplayWindowController {
                    existing.showWindow(nil)
                    existing.window?.makeMain()
                    return
                }

                // The console is only reachable once the domain is actually
                // running, which start() has just waited for.
                try await libvirtVM.connectConsole()

                let window = VMDisplayQemuMetalWindowController(vm: libvirtVM, onClose: { [weak self] in
                    guard let self = self else { return }
                    self.vmWindows.removeValue(forKey: vm)
                    Task { await libvirtVM.disconnectConsole() }
                })
                vmWindows[vm] = window
                libvirtVM.delegate = window
                window.showWindow(nil)
                window.window?.makeMain()
            } catch {
                self.alertItem = .message(error.localizedDescription)
            }
        }
    }
    #endif

    #if WITH_REMOTE_KVM
    /// Opens a serial console window for a remote domain.
    func openRemoteSerialConsole(vm: VMData, libvirtVM: UTMLibvirtVirtualMachine) {
        if let existing = vmWindows[vm] as? VMDisplayWindowController {
            existing.showWindow(nil)
            existing.window?.makeMain()
            return
        }
        guard #available(macOS 12, *) else { return }
        let window = VMDisplayLibvirtTerminalWindowController(vm: libvirtVM, onClose: { [weak self] in
            self?.vmWindows.removeValue(forKey: vm)
        })
        vmWindows[vm] = window
        libvirtVM.delegate = window
        window.showWindow(nil)
        window.window?.makeMain()
    }
    #endif

    /// Start a remote session and return SPICE server port.
    /// - Parameters:
    ///   - vm: VM to start
    ///   - options: Start options
    ///   - server: Remote server
    /// - Returns: Port number to SPICE server
    func startRemote(vm: VMData, options: UTMVirtualMachineStartOptions, forClient client: UTMRemoteServer.Remote) async throws -> UTMRemoteMessageServer.StartVirtualMachine.ServerInformation {
        guard let wrapped = vm.wrapped as? UTMQemuVirtualMachine, type(of: wrapped).capabilities.supportsRemoteSession else {
            throw UTMDataError.unsupportedBackend
        }
        if let existingSession = vmWindows[vm] as? VMRemoteSessionState, let spiceServerInfo = wrapped.spiceServerInfo {
            if wrapped.state == .paused {
                try await wrapped.resume()
            }
            existingSession.client = client
            return spiceServerInfo
        }
        guard vmWindows[vm] == nil else {
            throw UTMDataError.virtualMachineUnavailable
        }
        let session = VMRemoteSessionState(for: wrapped, client: client) {
            self.vmWindows.removeValue(forKey: vm)
        }
        try await wrapped.start(options: options.union(.remoteSession))
        vmWindows[vm] = session
        guard let spiceServerInfo = wrapped.spiceServerInfo else {
            throw UTMDataError.unsupportedBackend
        }
        return spiceServerInfo
    }

    func stop(vm: VMData) {
        guard let wrapped = vm.wrapped else {
            return
        }
        Task {
            if wrapped.registryEntry.isSuspended {
                try? await wrapped.deleteSnapshot(name: nil)
            }
            if vm.state == .started || vm.state == .paused {
                try? await wrapped.stop(usingMethod: .force)
            } else {
                try? await wrapped.stop(usingMethod: .kill)
            }
            await MainActor.run {
                self.close(vm: vm)
            }
        }
    }
    
    func close(vm: VMData) {
        if let window = vmWindows.removeValue(forKey: vm) as? VMDisplayWindowController {
            DispatchQueue.main.async {
                window.close()
            }
        }
    }
}
