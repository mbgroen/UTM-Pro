# Snapshots

A snapshot records a virtual machine's disk, and optionally its memory, so you
can return to that point later. UTM Pro manages snapshots for both local and
remote VMs.

Upstream UTM can save and restore a snapshot while a VM runs, but cannot list
them and cannot touch them at all while the VM is off. UTM Pro reads the list
from the disk image itself, which works either way.

## Opening

Select a VM and press **Snapshots…**. The window lists what exists, with each
snapshot's size and the moment it was taken.

## With or without memory

Each row says whether the snapshot captured memory, because it decides what
restoring does:

- **With memory** — restoring resumes execution exactly where it was, mid-run,
  as if the VM had never stopped
- **Disk only** — restoring returns the disk to that state and the VM boots
  from it

A snapshot taken while the VM runs captures memory. One taken while it is off
cannot, and does not.

## Restoring

Restoring replaces the current disk state. Anything written since the snapshot
was taken is gone, which is why it asks first.

For a running local VM the restore happens in place. For a remote domain,
libvirt reverts it — the VM's state afterwards is whatever the snapshot held.

## When a host refuses

UTM Pro checks that a VM has a disk that can hold a snapshot before offering to
create one, but a host can still refuse for reasons the disk format does not
reveal. The common one: libvirt will not take an internal snapshot of a UEFI
guest whose nvram file is not qcow2.

These errors are shown exactly as the host reports them, rather than being
rewritten into something friendlier and less accurate.

## What is used underneath

| | |
|---|---|
| Local, running | The QEMU monitor — `savevm`, `loadvm`, `delvm` |
| Local, stopped | `qemu-img snapshot` |
| Remote | `virsh snapshot-create-as`, `snapshot-revert`, `snapshot-delete` |

Listing always reads the image directly, with `--force-share` so it works while
a VM holds a write lock on it.
