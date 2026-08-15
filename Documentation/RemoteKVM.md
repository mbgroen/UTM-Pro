# Remote KVM management (UTM Pro)

Extends UTM to manage libvirt/KVM hosts alongside local VMs — specifically an
OpenMediaVault 8 NAS running the `openmediavault-kvm` plugin. Adds snapshot
management for both local and remote VMs, and storage pool/volume management on
remote hosts.

Target platforms: macOS and iOS/iPadOS.

## Why not the existing remote support

UTM already ships a remote mode, but it is a *whole-app* mode, not a per-VM one.
The `iOS-Remote` target compiles out the local QEMU backend (`#if !WITH_REMOTE`
in `Platform/VMData.swift`) and `UTMRemoteData` *replaces* the VM list rather
than adding to it (`Platform/UTMData.swift`). It also speaks UTM's own protocol
to another copy of UTM — not libvirt.

Coexistence of local and remote VMs in one app is therefore the core structural
change here, and it is deliberately additive: `UTMData.virtualMachines` keeps
its existing local-only meaning so that every existing call site (delete, clone,
save, export) is untouched. Remote VMs live in a parallel collection.

## Transport: SSH to libvirt

Management runs over SSH to the host, driving `virsh -c qemu:///system` and
`qemu-img`. This gives the full libvirt surface rather than the subset the OMV
plugin's RPC API exposes.

The OMV plugin reads its VM, pool and volume state from libvirt itself, so
changes made this way surface in the OMV web UI. The exception to verify per
object type is anything the plugin also mirrors into its own `config.xml`.

One SSH connection per host serves two purposes:

- **exec channels** for `virsh` / `qemu-img` commands
- **direct-tcpip channels** to tunnel the console port

Host keys are pinned on first connect (TOFU); a later mismatch is a hard error,
never a prompt-to-ignore. Credentials live in the Keychain.

### Console

The OMV VMs expose SPICE on `0.0.0.0` with no password (verified on
`Pi-hole`: `<graphics type='spice' port='5901' autoport='yes' listen='0.0.0.0'>`).
Rather than connect to that directly across the LAN, the console is tunnelled
through the same SSH connection and UTM connects to a local forwarded port. This
works unchanged if the host is later hardened to bind SPICE to localhost.

CocoaSpice already supports plaintext SPICE (`CSConnection initWithHost:port:`);
only `UTMSpiceIO` lacks an initializer for it. That is the sole change needed to
reuse UTM's entire existing renderer, input, audio and USB-redirection stack for
remote VMs.

## Layers

| Layer | Location | Contents |
|---|---|---|
| SSH | `Services/Remote/SSH/` | `UTMSSHConnection` over swift-nio-ssh: auth, host-key pinning, exec, local port forward, keepalive/reconnect |
| libvirt | `Services/Remote/Libvirt/` | `LibvirtHost` actor: typed async API for domains, snapshots, pools, volumes. Domain XML build/parse |
| Backend | `Services/` | `UTMLibvirtVirtualMachine` conforming to `UTMVirtualMachine`; `UTMLibvirtConfiguration` |
| Model | `Platform/` | `VMLibvirtData`, server registry on `UTMData` |
| UI | `Platform/Shared/` | Sidebar sections, server setup, snapshot manager, storage manager, remote VM wizard |

### Command safety

Every value interpolated into a `virsh` command line is shell-quoted. VM names,
pool names and volume names originate from user input and from the remote host;
neither is trusted. Command construction goes through a single builder so this
cannot be forgotten at a call site.

## Snapshots

The `UTMVirtualMachine` protocol already declares `saveSnapshot(name:)`,
`deleteSnapshot(name:)` and `restoreSnapshot(name:)`, but UTM's UI only ever
uses the single implicit suspend snapshot, and there is no way to list them.

- **List** is the missing primitive. Added as `listSnapshots()` on the protocol.
- **Local, running:** existing QMP path (`savevm`/`loadvm`/`delvm`).
- **Local, stopped:** `qemu-img snapshot -l/-c/-a/-d`, new methods on
  `UTMQemuImage`. This is new capability — today deleting a snapshot while the
  VM is off silently does nothing (`_deleteSnapshot` no-ops without a monitor).
- **Remote:** `virsh snapshot-list/-create-as/-revert/-delete`.

Internal qcow2 snapshots require qcow2 backing; drives that are raw or read-only
are reported as unsupported rather than failing at save time.

## Storage (remote)

Pools: list with capacity/allocation, define, build, start, stop, autostart,
delete, refresh. Volumes: list per pool, create, resize, clone, convert, delete.

Destructive operations (delete pool, delete volume, revert snapshot) confirm
with the object name typed back where the target is not recoverable.

## Build prerequisites

UTM cannot build without a prebuilt sysroot. Staged at repo root from the
upstream CI artifact `Sysroot-macos-arm64` (see `AGENTS.md`). Xcode 26 also
needs the Metal toolchain component:

    xcodebuild -downloadComponent MetalToolchain
