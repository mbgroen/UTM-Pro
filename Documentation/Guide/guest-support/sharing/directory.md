# Directory

Directory sharing allows a host directory to be shared with the guest. There are three supported backends for directory sharing:

1. **SPICE WebDAV** Requires SPICE webdavd to be installed and creates a local WebDAV server that is connected to the host. It is supported only by the QEMU backend and is compatible with Windows and Linux guests.
2. **VirtFS** Requires 9pfs drivers and is currently only supported by the QEMU backend running Linux. It has better transfer speeds than SPICE WebDAV.
3. **macOS 12+** **VirtioFS** Requires virtiofs drivers and is currently only supported by the Apple backend running Linux.

> [!NOTE]
> **macOS** Shared directories in macOS VMs are only available in macOS 13 and later (both guest and host).

## Selecting directory to share
This can be done [from the details view](../../basics/basics.md) near the bottom of the view.

## Mounting on guest
Windows guests can install [the guest tools](../windows.md) to enable SPICE WebDAV sharing. Linux guests have [a variety of options](../linux.md) for directory sharing.
