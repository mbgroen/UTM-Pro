# UTM Pro User Guide

UTM Pro runs virtual machines on your Mac, and manages virtual machines running
on remote libvirt/KVM hosts — a NAS, a server, anything reachable over SSH —
from the same window.

Everything about local VMs works as it does in UTM, and those pages are
reproduced here so the guide stays with the app it describes. The pages listed
under **Remote hosts** cover what UTM Pro adds.

## Remote hosts

This is what distinguishes UTM Pro. None of it exists upstream.

- [Remote hosts](remote-hosts/remote-hosts.md) — adding a server, SSH keys,
  consoles, and how a remote VM differs from a local one
- [Snapshots](remote-hosts/snapshots.md) — for local **and** remote VMs,
  including while a VM is stopped
- [Storage](remote-hosts/storage.md) — pools and volumes on a host
- [How it works](../RemoteKVM.md) — design notes and command-line verification

## Basics

- [Getting started](basics/basics.md)
- [Actions](basics/actions.md)
- [Controls](basics/controls.md)

## Guest support

- [Overview](guest-support/guest-support.md)
- [Linux](guest-support/linux.md) · [Windows](guest-support/windows.md) · [macOS](guest-support/macos.md)
- [Sharing](guest-support/sharing/sharing.md): [clipboard](guest-support/sharing/clipboard.md), [directories](guest-support/sharing/directory.md), [USB](guest-support/sharing/usb.md)
- [Dynamic resolution](guest-support/dynamic-resolution.md)

## Advanced

- [Overview](advanced/advanced.md)
- [Headless](advanced/headless.md) · [Serial](advanced/serial.md) · [Multiple displays](advanced/multiple-displays.md)
- [Disposable mode](advanced/disposable.md) · [Recovery](advanced/recovery.md) · [Rosetta](advanced/rosetta.md)
- [Scripting](advanced/scripting.md) · [Remote control](advanced/remote-control.md)

## Settings

- [QEMU virtual machines](settings-qemu/settings-qemu.md) — [system](settings-qemu/system.md), [QEMU](settings-qemu/qemu.md), [input](settings-qemu/input.md), [sharing](settings-qemu/sharing.md), [drives](settings-qemu/drive/drive.md), [devices](settings-qemu/devices/devices.md)
- [Apple virtual machines](settings-apple/settings-apple.md)
- [App preferences](preferences/preferences.md)

## Scripting

- [Overview](scripting/scripting.md) · [Cheat sheet](scripting/cheat-sheet.md)

## Sharing this Mac's VMs

Distinct from managing a remote KVM host: this shares VMs *running on this Mac*
so another device can display them.

- [Overview](remote/remote.md) · [Server setup](remote/server.md)

## Install guides

- [Debian](guides/debian.md) · [Ubuntu](guides/ubuntu.md) · [Fedora](guides/fedora.md) · [Kali](guides/kali.md)
- [Windows](guides/windows.md) · [Windows 10](guides/windows-10.md)
- [Classic macOS](guides/classic-macos.md) · [Classic Windows](guides/classic-windows.md)

---

The local-VM pages are adapted from the [UTM documentation][docs], which its
authors released under [CC0 1.0][cc0] — public domain, no attribution required.
Credited anyway, because they wrote it.

UTM Pro is a fork of [UTM][utm], which remains under the Apache 2.0 licence.

[docs]: https://docs.getutm.app/
[cc0]: https://creativecommons.org/publicdomain/zero/1.0/
[utm]: https://github.com/utmapp/UTM
