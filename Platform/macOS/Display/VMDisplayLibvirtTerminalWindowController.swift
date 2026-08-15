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

#if os(macOS) && WITH_REMOTE_KVM

import Foundation
import LibvirtKit
import SwiftTerm

/// A serial console for a remote libvirt domain.
///
/// The guest's serial port is a pty on the host, not something SPICE carries,
/// so this drives `virsh console` over its own SSH channel rather than going
/// through the display stack. That makes it the only way to see a VM with no
/// graphics at all — which describes most server VMs.
@available(macOS 12, *)
class VMDisplayLibvirtTerminalWindowController: VMDisplayWindowController {
    private var terminalView: TerminalView!
    private var session: SSHShellSession?

    /// Derived rather than stored: the base class's initializer is a
    /// convenience one, so a subclass cannot chain to it from a designated
    /// init to stash a second reference to the same VM.
    private var libvirtVM: UTMLibvirtVirtualMachine {
        vm as! UTMLibvirtVirtualMachine
    }

    override func windowDidLoad() {
        terminalView = TerminalView(frame: displayView.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        displayView.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: displayView.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: displayView.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: displayView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: displayView.trailingAnchor),
        ])
        terminalView.terminalDelegate = self
        super.windowDidLoad()

        window?.title = libvirtVM.domainName
        window?.subtitle = NSLocalizedString("Serial Console", comment: "VMDisplayLibvirtTerminalWindowController")

        Task { await connect() }
    }

    override func enterLive() {
        // None of the display controls apply to a serial console.
        setControl(.resize, isEnabled: false)
        setControl(.usb, isEnabled: false)
        setControl(.drives, isEnabled: false)
        super.enterLive()
    }

    private func connect() async {
        do {
            let session = try await libvirtVM.openSerialConsole { [weak self] data in
                Task { @MainActor in
                    self?.feed(data)
                }
            } onClose: { [weak self] in
                Task { @MainActor in
                    self?.appendNotice(NSLocalizedString("Console closed.", comment: "VMDisplayLibvirtTerminalWindowController"))
                }
            }
            self.session = session
            appendNotice(NSLocalizedString("Connected. Press Enter if the guest shows nothing — a getty only prints its prompt when it sees input.", comment: "VMDisplayLibvirtTerminalWindowController"))
        } catch {
            appendNotice(String(format: NSLocalizedString("Could not open the console: %@", comment: "VMDisplayLibvirtTerminalWindowController"), error.localizedDescription))
        }
    }

    @MainActor private func feed(_ data: Data) {
        terminalView.feed(byteArray: ArraySlice(data))
    }

    /// Writes a line from us, not the guest, so it is visually distinct from
    /// whatever the VM is printing.
    @MainActor private func appendNotice(_ text: String) {
        let line = "\r\n\u{001B}[2m— \(text)\u{001B}[0m\r\n"
        terminalView.feed(text: line)
    }

    override func windowWillClose(_ notification: Notification) {
        session?.close()
        session = nil
        super.windowWillClose(notification)
    }
}

@available(macOS 12, *)
extension VMDisplayLibvirtTerminalWindowController: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(width: newCols, height: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    }

    func scrolled(source: TerminalView, position: Double) {
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
    }
}

#endif
