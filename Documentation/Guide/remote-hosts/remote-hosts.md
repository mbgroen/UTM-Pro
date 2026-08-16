# Remote Hosts

UTM Pro can manage virtual machines running on another machine — a NAS, a home
server, a workstation — as long as it runs libvirt/KVM and you can reach it over
SSH. Those VMs appear in the sidebar beside the ones on this Mac.

Nothing is installed on the host. UTM Pro runs `virsh` and `qemu-img` over an
SSH connection, which is what an administrator would type by hand.

## What the host needs

- libvirt with the QEMU/KVM driver, reachable as `qemu:///system`
- An SSH account whose user may talk to libvirt — commonly `root`, or a member
  of the `libvirt` group
- `virsh` and `qemu-img` on the host's `PATH`

Tested against OpenMediaVault 8 with its KVM plugin, but nothing in UTM Pro is
specific to it.

## Adding a server

Press **Add Server** in the sidebar and fill in the address and username.

> [!IMPORTANT]
> Only Ed25519 and ECDSA keys work. RSA keys are **not** supported — the SSH
> implementation UTM Pro uses does not accept them. If an RSA key is all you
> have, press **Generate a New Key** in the form and install the new one.

After generating a key, copy the public half and add it to `~/.ssh/authorized_keys`
for that account on the host. If you use `ssh-copy-id` and it says the key is
already installed when it is not, pass `-f`: it decides by logging in, so an
existing working key makes it skip the new one.

Press **Test Connection** before saving. It connects once, reads the host's
details, and changes nothing.

## Connecting

Saved servers do **not** connect when the app launches. Connect from the
server's `⋯` menu. This is deliberate: a server that is asleep, off the network,
or behind a VPN should not make the app hang at startup, and a stored credential
should not be used without you asking for it.

The first connection records the host's key fingerprint. It is checked on every
later connection, and a change is reported rather than accepted. To accept a
genuinely new key — after a host rebuild, say — use **Forget Host Key** in the
server's advanced settings.

## Working with a remote VM

Most things behave as they do locally. These do not, and the differences are
intentional:

| | |
|---|---|
| **Closing the console window** | Disconnects only. The VM keeps running — it does not belong to this app's lifetime, so closing a window never stops it |
| **Settings** | Show the domain as the host reports it. Saving sends back only the fields you changed, so anything UTM Pro does not model is left alone |
| **Adding hardware** | The **New…** menu adds it to the domain on its host. It offers drives and network interfaces — what libvirt can add to a defined domain |
| **Deleting** | Asks separately whether to delete the disk images. Removing the domain leaves the storage untouched otherwise |

## Consoles

A VM's graphical console reaches you over the SSH connection by default, so the
host's console port never has to be exposed to the network. That port is
normally unauthenticated, which is why tunnelling is the default; turn it off
only if the port is already protected.

On macOS, a running VM also offers **Serial Console…**, which attaches to the
domain's serial device over SSH — useful when the graphical console shows
nothing and you need to see the boot messages.

If a console fails to open right after starting a VM, the host had not yet
assigned a console port. Try again; UTM Pro re-reads the domain each time.

## Related

- [Snapshots](snapshots.md)
- [Storage](storage.md)
- [How it works](../../RemoteKVM.md) — design notes, and how to verify a
  connection from the command line
