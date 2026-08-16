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

import AppKit

/// Snapshots from the console window.
///
/// The snapshot browser lives in the VM list, which is exactly where you are
/// not when you want a snapshot: you are looking at the guest, about to do
/// something you might regret. This offers the two operations worth having in
/// that moment and leaves managing the rest where it was.
extension VMDisplayWindowController {
    @IBAction dynamic func snapshotButtonPressed(_ sender: Any) {
        let menu = NSMenu()
        updateSnapshotMenu(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc dynamic func updateSnapshotMenu(_ menu: NSMenu) {
        let save = NSMenuItem(title: NSLocalizedString("Save Snapshot…", comment: "VMDisplayWindowController"),
                              action: #selector(saveSnapshotPressed),
                              keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let restore = NSMenuItem(title: NSLocalizedString("Restore Snapshot…", comment: "VMDisplayWindowController"),
                                 action: #selector(restoreSnapshotPressed),
                                 keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
    }

    // MARK: - Save

    @objc private func saveSnapshotPressed() {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Save Snapshot", comment: "VMDisplayWindowController")
        alert.informativeText = NSLocalizedString("The virtual machine's current state is recorded so you can return to it later.", comment: "VMDisplayWindowController")
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "VMDisplayWindowController"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "VMDisplayWindowController"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = NSLocalizedString("Name", comment: "VMDisplayWindowController")
        field.stringValue = defaultSnapshotName()
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            Task {
                do {
                    try await self.vm.saveSnapshot(name: name.isEmpty ? nil : name)
                } catch {
                    await MainActor.run { self.showErrorAlert(error.localizedDescription) }
                }
            }
        }
    }

    /// Distinct without being cryptic, so a list of them stays readable.
    private func defaultSnapshotName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date())
    }

    // MARK: - Restore

    @objc private func restoreSnapshotPressed() {
        Task {
            let snapshots: [UTMVirtualMachineSnapshot]
            do {
                snapshots = try await vm.listSnapshots()
            } catch {
                await MainActor.run { self.showErrorAlert(error.localizedDescription) }
                return
            }
            await MainActor.run { self.presentRestore(snapshots) }
        }
    }

    @MainActor
    private func presentRestore(_ snapshots: [UTMVirtualMachineSnapshot]) {
        guard let window = window else { return }
        guard !snapshots.isEmpty else {
            showErrorAlert(NSLocalizedString("This virtual machine has no snapshots yet.", comment: "VMDisplayWindowController"))
            return
        }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restore Snapshot", comment: "VMDisplayWindowController")
        alert.informativeText = NSLocalizedString("Everything written since the snapshot was taken will be lost.", comment: "VMDisplayWindowController")
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: "VMDisplayWindowController"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "VMDisplayWindowController"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 25), pullsDown: false)
        for snapshot in snapshots {
            // Whether memory was captured decides whether restoring resumes
            // mid-execution or boots, so it belongs on the row and not in a
            // footnote nobody reads.
            var title = snapshot.name
            if snapshot.includesMemory {
                title += NSLocalizedString(" (with memory)", comment: "VMDisplayWindowController")
            }
            popup.addItem(withTitle: title)
        }
        if let current = snapshots.firstIndex(where: { $0.isCurrent }) {
            popup.selectItem(at: current)
        }
        alert.accessoryView = popup

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let snapshot = snapshots[popup.indexOfSelectedItem]
            Task {
                do {
                    try await self.vm.restoreSnapshot(name: snapshot.name)
                } catch {
                    await MainActor.run { self.showErrorAlert(error.localizedDescription) }
                }
            }
        }
    }
}
