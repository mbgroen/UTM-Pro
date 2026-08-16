# Storage

A libvirt host keeps disk images in **storage pools**. Each pool holds
**volumes** — the individual disk images. UTM Pro manages both, so you do not
have to switch to the host's own web interface to make room for a VM.

Open it from a server's `⋯` menu → **Storage**.

## Pools

The list shows each pool's state and how full it is. From here you can define a
new pool, build and start it, set it to start on boot, stop it, rescan it, or
undefine it.

Undefining a pool removes libvirt's record of it. The directory and the images
inside stay where they are.

## Volumes

Press **Show Volumes** on a pool to see what is in it. From there:

- **Create** a new volume, choosing its format and size
- **Resize** an existing one
- **Clone** a volume — useful as a template
- **Delete** a volume

### Two sizes

Each volume shows its virtual size and its actual size separately. A sparse
qcow2 image is allocated far larger than the space it occupies, and collapsing
the two would make a pool look full when it is mostly empty.

### Deleting

Deleting asks you to type the volume's name, and tells you if a VM is currently
using the image. libvirt will not stop you deleting a disk out from under a
running guest, so the confirmation is the only thing standing between a typo and
a broken VM.

### Shrinking

Making a volume smaller requires confirming that you already shrank the guest's
filesystem. libvirt discards whatever lies past the new end without looking at
what is there.

## Attaching a volume to a VM

Use **New…** → **Drive** in a remote VM's settings. You can point it at a volume
that already exists in a pool, or create one as part of adding the drive.

The drive is attached persistently, so it is still there after a reboot. If the
VM is running, whether the guest notices the new disk straight away depends on
the guest supporting hotplug; a reboot always shows it.
